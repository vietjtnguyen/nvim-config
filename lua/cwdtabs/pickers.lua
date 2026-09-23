-- Telescope pickers for cwdtabs-style navigation. This submodule pulls in
-- telescope, so the core (cwdtabs/init.lua) never requires it directly and
-- stays finder-agnostic; setup() wires the pickers through <Plug> mappings and
-- :CwdTabsPick* commands that load this module lazily, only when a picker is
-- actually invoked. Two pickers are views over the live tab model
-- (require('cwdtabs').groups()); the zoxide picker is sourced from the zoxide
-- directory database and re-roots a tab with :tcd, which cwdtabs' DirChanged
-- autocmd then regroups -- same derive-only model, just seeded from where you've
-- been rather than where your tabs are.

local cwdtabs = require('cwdtabs')
local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local previewers = require('telescope.previewers')
local putils = require('telescope.previewers.utils')

local M = {}

local function goto_tab(id)
  if id and vim.api.nvim_tabpage_is_valid(id) then
    vim.api.nvim_set_current_tabpage(id)
  end
end

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return data
end

-- Full process chain running in a terminal buffer, e.g. "zsh -> claude" or
-- "zsh -> docker". Walks /proc from the terminal's job PID down to its deepest
-- descendant (following the most recently spawned child at each step). Linux
-- only; returns nil elsewhere or when undeterminable, so callers fall back to
-- the plain command name.
local function term_chain(bufnr)
  local pid = vim.b[bufnr] and vim.b[bufnr].terminal_job_pid
  if not pid then return nil end
  local names = {}
  for _ = 1, 16 do
    local comm = read_file('/proc/' .. pid .. '/comm')
    if not comm then break end
    names[#names + 1] = (comm:gsub('%s+$', ''))
    local kids = read_file('/proc/' .. pid .. '/task/' .. pid .. '/children')
    local last
    for c in (kids or ''):gmatch('%d+') do last = c end
    if not last then break end
    pid = tonumber(last)
  end
  if #names == 0 then return nil end
  return table.concat(names, ' → ')
end

-- Size a picker to its entry count. Telescope computes layout once at open
-- (and on resize), not per-keystroke, so this fits the *initial* number of
-- tabs -- a handful of tabs opens a compact list, not a half-empty half-screen
-- -- but it does not shrink further as you filter. With a previewer we stack
-- vertically (results above, preview below) so both get the full window width;
-- the ~6 lines of slack absorb the prompt and window borders (tune to taste).
local function layout_for(entries, previewer)
  local n = #entries
  if previewer then
    local preview_h = 18
    return {
      layout_strategy = 'vertical',
      layout_config = {
        mirror = true,             -- results on top, preview below
        prompt_position = 'top',
        width = 0.8,
        height = function(_, _, max_lines)
          return math.min(max_lines - 2, n + preview_h + 6)
        end,
        preview_height = function(_, _, max_lines)
          return math.min(preview_h, math.max(6, max_lines - n - 8))
        end,
      },
    }
  end
  return {
    layout_config = {
      height = function(_, _, max_lines)
        return math.min(max_lines - 2, n + 6)
      end,
    },
  }
end

-- Run a picker whose entries each carry a `.tab` id to switch to on <CR>.
local function run(title, entries, previewer, opts)
  opts = vim.tbl_deep_extend(
    'force', layout_for(entries, previewer), opts or {})
  pickers.new(opts, {
    prompt_title = title,
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e)
        return { value = e, display = e.display, ordinal = e.ordinal }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewer,
    attach_mappings = function(bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(bufnr)
        if entry then goto_tab(entry.value.tab) end
      end)
      return true
    end,
  }):find()
end

-- Preview a tab by dumping its active buffer's contents (works for files,
-- terminals, and any other loaded buffer). dyn_title puts the selected tab's
-- full path (terminals: their process chain / term:// URL) in the preview
-- border, complementing the shortened "./..." location shown inline in the
-- list. Requires dynamic_preview_title = true in the Telescope setup.
local function tab_previewer()
  return previewers.new_buffer_previewer({
    dyn_title = function(_, entry)
      return entry.value.title or 'Tab preview'
    end,
    define_preview = function(self, entry)
      local buf = entry.value.bufnr
      local pbuf = self.state.bufnr
      if buf and vim.api.nvim_buf_is_valid(buf) then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
        local ft = vim.bo[buf].filetype
        if ft ~= '' then putils.highlighter(pbuf, ft) end
      else
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { '(no preview)' })
      end
    end,
  })
end

-- Locate a file relative to its tab's CWD group, for the dimmed suffix in the
-- list. "./sub/dir/file.c" when it's inside the group (the common case, kept
-- short); the full ~ path when it lives elsewhere; empty for a buffer with no
-- file (a terminal). g.cwd is already normalized; normalize the buffer path too
-- so the prefix test is apples-to-apples.
local function locate(cwd, file)
  if not file then return '' end
  local nfile = vim.fs.normalize(file)
  local prefix = cwd:gsub('/*$', '') .. '/'
  if nfile:sub(1, #prefix) == prefix then
    return './' .. nfile:sub(#prefix + 1)
  end
  return vim.fn.fnamemodify(nfile, ':~')
end

-- Pick any tab across all groups. The current tab is marked '●'. Each line is
-- "group › <tab>" (never clipped) followed by the buffer's location, dimmed --
-- see locate(). The full path is also in the ordinal, so a fuzzy query matches
-- on it even where the line shows only the short "./..." form.
function M.pick_tabs(opts)
  local entries = {}
  for _, g in ipairs(cwdtabs.groups()) do
    for _, t in ipairs(g.tabs) do
      local is_term = t.path:match('^term://')
      local file = (t.path ~= '' and not is_term) and t.path
      -- For terminals, show the running process chain (zsh -> claude) instead
      -- of the bare shell; falls back to the tabline label if unavailable.
      local label = t.label
      local chain
      if is_term then
        chain = term_chain(t.bufnr)
        if chain then label = t.nr .. ' ' .. chain end
      end
      local mark = t.is_current and '●' or ' '
      local head = string.format('%s %s › %s', mark, g.label, label)
      local loc = locate(g.cwd, file)
      -- Preview border title: the file's full ~ path, else a terminal's process
      -- chain or its term:// URL (see tab_previewer's dyn_title).
      local title = file and vim.fn.fnamemodify(file, ':~') or chain or t.path
      entries[#entries + 1] = {
        tab = t.id,
        bufnr = t.bufnr,
        title = title,
        ordinal = table.concat({ g.label, g.cwd, label, file or '' }, ' '),
        -- Return (line, highlights): dim only the appended "(location)" so the
        -- tab info stays at full contrast. Ranges are 0-indexed byte columns;
        -- #head is the byte length of the head, i.e. where the suffix starts.
        display = function()
          if loc == '' then return head end
          local line = head .. '  (' .. loc .. ')'
          return line, { { { #head, #line }, 'Comment' } }
        end,
      }
    end
  end
  run('Tabs', entries, tab_previewer(), opts)
end

-- Pick a CWD group; opens its first tab. A '●' marks the current group.
function M.pick_groups(opts)
  local entries = {}
  for _, g in ipairs(cwdtabs.groups()) do
    entries[#entries + 1] = {
      tab = g.tabs[1].id,
      display = string.format('%s %-16s (%d)  %s',
        g.has_current and '●' or ' ', g.label, #g.tabs,
        vim.fn.fnamemodify(g.cwd, ':~')),
      ordinal = g.label .. ' ' .. g.cwd,
    }
  end
  run('Tab groups (CWD)', entries, nil, opts)
end

-- Re-root a tab on `dir`: <CR> :tcd's the current tab (like gGc, but to any
-- zoxide dir), <C-t> opens `dir` in a NEW tab as a netrw listing and :tcd's that
-- tab to it. Either way the :tcd fires DirChanged, so cwdtabs regroups on its
-- own -- we don't touch the grouping. A zoxide entry can outlive its directory
-- (zoxide only prunes on its own writes), so guard existence and report rather
-- than let :tcd/:tabedit throw. The "tcd →" message matches cwdtabs.tcd_to_buffer.
local function open_zoxide_dir(dir, in_new_tab)
  if vim.fn.isdirectory(dir) == 0 then
    vim.notify('cwdtabs: no such directory: ' .. dir, vim.log.levels.WARN)
    return
  end
  local esc = vim.fn.fnameescape(dir)
  if in_new_tab then vim.cmd('tabedit ' .. esc) end
  vim.cmd('tcd ' .. esc)
  vim.notify('tcd → ' .. dir)
end

-- Pick a directory from the zoxide database (frecency order, like `zi`) and
-- re-root a tab on it -- <CR> the current tab, <C-t> a new tab. The current
-- tab's directory is marked '●'. zoxide lists newest/most-frecent first and an
-- empty telescope query preserves that order, so the top entries are your most
-- frequented dirs. Sourced synchronously: `zoxide query --list` is a fast
-- one-shot on an explicit keypress, not a hot path.
function M.pick_zoxide(opts)
  if vim.fn.executable('zoxide') == 0 then
    vim.notify('cwdtabs: zoxide not found on PATH', vim.log.levels.WARN)
    return
  end
  local dirs = vim.fn.systemlist({ 'zoxide', 'query', '--list' })
  if vim.v.shell_error ~= 0 or #dirs == 0 then
    vim.notify('cwdtabs: no zoxide directories', vim.log.levels.WARN)
    return
  end

  local cur = vim.fs.normalize(vim.fn.getcwd(-1, vim.fn.tabpagenr()))
  local entries = {}
  for _, dir in ipairs(dirs) do
    local mark = (vim.fs.normalize(dir) == cur) and '●' or ' '
    entries[#entries + 1] = {
      dir = dir,
      display = mark .. ' ' .. vim.fn.fnamemodify(dir, ':~'),
      -- Match on both the ~-contracted and absolute forms of the path.
      ordinal = vim.fn.fnamemodify(dir, ':~') .. ' ' .. dir,
    }
  end

  opts = vim.tbl_deep_extend('force', layout_for(entries, nil), opts or {})
  pickers.new(opts, {
    prompt_title = 'Zoxide → tcd',
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e)
        return { value = e, display = e.display, ordinal = e.ordinal }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(bufnr)
        if entry then open_zoxide_dir(entry.value.dir, false) end
      end)
      map({ 'i', 'n' }, '<C-t>', function()
        local entry = action_state.get_selected_entry()
        actions.close(bufnr)
        if entry then open_zoxide_dir(entry.value.dir, true) end
      end)
      return true
    end,
  }):find()
end

return M

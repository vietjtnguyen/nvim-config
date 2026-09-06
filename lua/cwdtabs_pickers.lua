-- Telescope pickers over the cwdtabs model. Kept out of the cwdtabs core, which
-- stays finder-agnostic; this is the config-level Telescope view of it, built
-- on the public require('cwdtabs').groups() data.

local cwdtabs = require('cwdtabs')
local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local entry_display = require('telescope.pickers.entry_display')
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

-- Run a picker whose entries each carry a `.tab` id to switch to on <CR>.
local function run(title, entries, previewer, opts)
  opts = opts or {}
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
-- terminals, and any other loaded buffer).
local function tab_previewer()
  return previewers.new_buffer_previewer({
    title = 'Tab preview',
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

-- Pick any tab across all groups. The current tab is marked '●'; the buffer's
-- ~-path is shown and, with the group name and CWD, is fuzzy-searchable. A
-- preview pane shows the tab's active buffer.
function M.pick_tabs(opts)
  local displayer = entry_display.create({
    separator = ' ',
    items = { { width = 1 }, { width = 30 }, { remaining = true } },
  })
  local entries = {}
  for _, g in ipairs(cwdtabs.groups()) do
    for _, t in ipairs(g.tabs) do
      local is_term = t.path:match('^term://')
      local file = (t.path ~= '' and not is_term) and t.path
      -- For terminals, show the running process chain (zsh -> claude) instead
      -- of the bare shell; falls back to the tabline label if unavailable.
      local label = t.label
      if is_term then
        local chain = term_chain(t.bufnr)
        if chain then label = t.nr .. ' ' .. chain end
      end
      local head = string.format('%s › %s', g.label, label)
      local mark = t.is_current and '●' or ' '
      local path = file and vim.fn.fnamemodify(file, ':~') or ''
      entries[#entries + 1] = {
        tab = t.id,
        bufnr = t.bufnr,
        ordinal = table.concat({ g.label, g.cwd, label, file or '' }, ' '),
        display = function()
          return displayer({ mark, head, { path, 'Comment' } })
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

return M

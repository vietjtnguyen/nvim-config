-- cwdtabs: a grouped tabline that discovers structure from tab-local CWDs.
--
-- The whole model is derived, never stored: tabs are grouped by the normalized
-- effective CWD of each tabpage (its :tcd, or the global cwd if it has none).
-- Two tabs are "in the same group" iff those normalized CWDs are string-equal.
-- There is no project registry -- delete this file and you're left with plain
-- Neovim tabs and their tab-local CWDs, untouched.
--
-- It renders that grouping onto Neovim's native (one-line) tabline and adds
-- group-level navigation (see Navigation).

local M = {}

--------------------------------------------------------------------------------
-- Data model
--------------------------------------------------------------------------------

-- Effective, normalized CWD of a tabpage, queried WITHOUT switching to it.
-- getcwd(-1, tabnr): the -1 means "ignore any window-local :lcd, use the tab's
-- directory" -- and if the tab has no :tcd, it falls through to the global cwd.
-- That fall-through is exactly the "effective" CWD we want to group on.
-- vim.fs.normalize collapses ~, ., and trailing slashes; it deliberately does
-- NOT resolve symlinks (conservative, per design), so two tabs reaching one
-- repo via different symlink paths form separate groups -- a known limitation.
local function tab_cwd(tabnr)
  return vim.fs.normalize(vim.fn.getcwd(-1, tabnr))
end

-- Label shown for a group: the final path component (basename). Root or an
-- empty basename falls back to the full path. Two distinct dirs can share a
-- basename (~/a/src vs ~/b/src) -- not disambiguated in Stage 1.
local function group_label(cwd)
  local base = vim.fs.basename(cwd)
  if base == nil or base == '' then return cwd end
  return base
end

-- Label for a single tab: the tab number, then the active window's buffer
-- basename (number kept even with a buffer loaded, so <n>gt is discoverable).
-- A nameless tab shows just its number. Wrapped by the caller in pcall since
-- window/buffer handles can briefly be invalid during teardown.
local function tab_label(tab_id, tabnr)
  local win = vim.api.nvim_tabpage_get_win(tab_id)
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype == 'terminal' then
    -- A terminal buffer's name is the term://{cwd}//{pid}:{cmd} URL, whose
    -- plain basename is garbled. Show a '$' marker plus the invoked command's
    -- basename, parsed from the URL (stable, unlike b:term_title, which running
    -- programs overwrite). '$' reads as "shell" and renders in any font.
    local cmd = (vim.api.nvim_buf_get_name(buf)):match(':([^:]+)$')
    return tabnr .. ' $' .. (cmd and vim.fs.basename(cmd) or 'term')
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then return tostring(tabnr) end
  return tabnr .. ' ' .. vim.fs.basename(name)
end

-- Walk all tabpages once, in tab order, and bucket them by normalized CWD.
-- Group order = first appearance; because we iterate in tab-number order, that
-- means "ordered by the lowest tab number each group contains" -- stable and
-- intuitive, with no stored ordering. Tabs within a group stay in tab order.
local function build_groups()
  local current = vim.api.nvim_get_current_tabpage()
  local by_cwd = {}   -- cwd -> group table
  local order = {}    -- groups in first-appearance order

  for _, tab_id in ipairs(vim.api.nvim_list_tabpages()) do
    local tabnr = vim.api.nvim_tabpage_get_number(tab_id)
    local cwd = tab_cwd(tabnr)
    local group = by_cwd[cwd]
    if not group then
      group = { cwd = cwd, tabs = {}, has_current = false }
      by_cwd[cwd] = group
      order[#order + 1] = group
    end
    local is_current = (tab_id == current)
    if is_current then group.has_current = true end
    group.tabs[#group.tabs + 1] =
      { id = tab_id, nr = tabnr, is_current = is_current }
  end

  return order
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

-- Tabline format-code primer:
--   %#Group#   switch to highlight group "Group" for following text
--   %nT        start a click region that selects tab number n on mouse click
--   %T         end the current click region
--   %%         a literal percent (so dynamic text must be escaped)
-- The tabline is an *expression* re-evaluated on every redraw, so render() just
-- returns the whole string fresh each time -- there's nowhere to cache state,
-- which is exactly why the derive-don't-store model fits.

local function hl(group) return '%#' .. group .. '#' end

-- Escape user-derived text so a stray % in a path/buffer name isn't read as a
-- format code.
local function esc(s) return (s:gsub('%%', '%%%%')) end

local SEP = ' │ ' -- between groups

function M.render()
  local ok, out = pcall(function()
    local parts = {}
    local groups = build_groups()

    for gi, group in ipairs(groups) do
      if gi > 1 then
        parts[#parts + 1] = hl('CwdTabsFill') .. SEP
      end

      -- Group label, clickable: selects the group's first tab (native %nT
      -- click target). The current tab's group is highlighted distinctly.
      parts[#parts + 1] = '%' .. group.tabs[1].nr .. 'T'
        .. hl(group.has_current and 'CwdTabsGroupSel' or 'CwdTabsGroup')
        .. ' ' .. esc(group_label(group.cwd)) .. ':'
        .. '%T'

      -- Tabs in this group, each a native click target selecting that tab.
      for _, tab in ipairs(group.tabs) do
        local label = select(2, pcall(tab_label, tab.id, tab.nr))
        if type(label) ~= 'string' then label = tostring(tab.nr) end
        parts[#parts + 1] = '%' .. tab.nr .. 'T'
          .. hl(tab.is_current and 'TabLineSel' or 'TabLine')
          .. ' ' .. esc(label) .. ' '
          .. '%T'
      end
    end

    -- Fill the rest of the line and make sure no click region dangles.
    parts[#parts + 1] = hl('CwdTabsFill') .. '%T'
    return table.concat(parts)
  end)

  if not ok then
    -- Never let a render error spam the tabline; show a terse marker instead.
    return '%#ErrorMsg# cwdtabs error %#CwdTabsFill#'
  end
  return out
end

--------------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------------

-- Jump to the group `delta` positions from the current tab's group (wrapping
-- around), landing on that group's first tab. Analogous to gt/gT but one level
-- up. No-op with fewer than two groups. (A future refinement could land on the
-- group's most-recently-used tab instead of its first.)
local function goto_group(delta)
  local groups = build_groups()
  if #groups < 2 then return end

  local cur_idx
  for i, g in ipairs(groups) do
    if g.has_current then cur_idx = i break end
  end
  if not cur_idx then return end

  local target = (cur_idx - 1 + delta) % #groups + 1
  vim.api.nvim_set_current_tabpage(groups[target].tabs[1].id)
end

function M.next_group() goto_group(1) end
function M.prev_group() goto_group(-1) end

-- Track the previously-focused group's CWD so gG<Tab> can toggle back to it,
-- mirroring g<Tab> for tabs. Minimal transient state: just the current and
-- prior group CWDs, updated when focus lands on a different group (a tab
-- switch, or a :tcd that moves the current tab). Nothing persisted.
local focus = { current = nil, prev = nil }

local function track_focus()
  local cwd = tab_cwd(vim.fn.tabpagenr())
  if cwd ~= focus.current then
    focus.prev = focus.current
    focus.current = cwd
  end
end

-- Jump to the most recently focused *other* group (its first tab). No-op if we
-- haven't left a group yet, or that group no longer has any tabs.
function M.last_group()
  local target = focus.prev
  if not target then return end
  for _, tab_id in ipairs(vim.api.nvim_list_tabpages()) do
    if tab_cwd(vim.api.nvim_tabpage_get_number(tab_id)) == target then
      vim.api.nvim_set_current_tabpage(tab_id)
      return
    end
  end
end

-- :tcd the current tab to the directory of the current buffer, to "recenter"
-- the tab's project context where you are. A netrw/vim-vinegar listing uses
-- the browsed directory (b:netrw_curdir); a file uses its parent directory.
-- No-op (with a message) for buffers with no directory (terminals, [No Name]).
-- The DirChanged autocmd then regroups and redraws the tabline automatically.
function M.tcd_to_buffer()
  local dir
  -- Use the browsed directory only in a real netrw listing. b:netrw_curdir
  -- lingers on ordinary file buffers reached *through* netrw (still pointing
  -- at the last-browsed dir), so trusting it unconditionally would cd to the
  -- wrong place -- gate it on filetype == 'netrw'.
  local netrw = vim.b.netrw_curdir
  if vim.bo.filetype == 'netrw' and netrw and netrw ~= '' then
    dir = netrw
  else
    local name = vim.api.nvim_buf_get_name(0)
    if name == '' then
      vim.notify('cwdtabs: current buffer has no directory',
        vim.log.levels.WARN)
      return
    end
    dir = vim.fn.isdirectory(name) == 1 and name or vim.fs.dirname(name)
  end
  dir = vim.fs.normalize(dir)
  if vim.fn.isdirectory(dir) == 0 then
    vim.notify('cwdtabs: no directory for this buffer', vim.log.levels.WARN)
    return
  end
  vim.cmd('tcd ' .. vim.fn.fnameescape(dir))
  vim.notify('tcd → ' .. dir)
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

-- Our highlight groups link to sensible built-ins so themes drive the colors.
-- Reassert on ColorScheme because loading a theme can clear custom links.
local function set_highlights()
  vim.api.nvim_set_hl(0, 'CwdTabsGroup', { link = 'Directory' })
  vim.api.nvim_set_hl(0, 'CwdTabsGroupSel', { link = 'Title' })
  vim.api.nvim_set_hl(0, 'CwdTabsFill', { link = 'TabLineFill' })
end

-- Repaint the tabline now. A programmatic same-tab :tcd triggers no natural
-- screen redraw, and :redrawtabline only marks the tabline dirty without
-- flushing, so prefer nvim__redraw with flush; fall back to :redrawtabline if
-- that (private) API is ever unavailable.
local function redraw_tabline()
  if vim.api.nvim__redraw then
    vim.api.nvim__redraw({ tabline = true, flush = true })
  else
    vim.cmd('redrawtabline')
  end
end

-- The mappings installed by setup{ default_keymaps = true }. Kept in one place
-- so cwdtabs-mappings in the help can show the exact equivalent for users who
-- prefer to bind their own keys.
local function set_default_keymaps()
  local map = vim.keymap.set
  map('n', 'gGt', M.next_group, { desc = 'Next tab group (CWD)' })
  map('n', 'gGT', M.prev_group, { desc = 'Prev tab group (CWD)' })
  map('n', 'gG<Tab>', M.last_group, { desc = 'Last-used tab group (CWD)' })
  map('n', 'gGc', M.tcd_to_buffer, { desc = 'tcd tab to buffer dir' })
end

-- User commands, created by setup(): thin wrappers over the public functions.
local function set_commands()
  local cmd = vim.api.nvim_create_user_command
  cmd('CwdTabsNext', M.next_group, { desc = 'cwdtabs: next tab group' })
  cmd('CwdTabsPrev', M.prev_group, { desc = 'cwdtabs: previous tab group' })
  cmd('CwdTabsLast', M.last_group, { desc = 'cwdtabs: last-used tab group' })
  cmd('CwdTabsRecenter', M.tcd_to_buffer,
    { desc = 'cwdtabs: recenter tab on buffer dir' })
end

local defaults = {
  default_keymaps = false, -- install the gG* mappings
}

function M.setup(opts)
  opts = vim.tbl_extend('force', defaults, opts or {})

  set_highlights()
  focus.current = tab_cwd(vim.fn.tabpagenr())

  local group = vim.api.nvim_create_augroup('cwdtabs', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme',
    { group = group, callback = set_highlights })

  -- Recompute focus tracking and repaint the tabline on events that can change
  -- the grouping: tab created/closed, current tab changed, or any CWD change
  -- (:tcd fires DirChanged scope 'tabpage'; a global :cd fires 'global' and can
  -- move the no-:tcd tabs, so we listen to all scopes -- the default '*'
  -- pattern). TabClosed fires AFTER the tab is gone, so render() always
  -- recomputes from scratch and never caches tab indices. The repaint is
  -- scheduled to run after the triggering command finishes.
  vim.api.nvim_create_autocmd(
    { 'TabNew', 'TabClosed', 'TabEnter', 'DirChanged' }, {
    group = group,
    callback = function()
      track_focus()
      vim.schedule(redraw_tabline)
    end,
  })

  vim.o.showtabline = 2
  vim.o.tabline = '%!v:lua.require("cwdtabs").render()'

  set_commands()
  if opts.default_keymaps then
    set_default_keymaps()
  end
end

return M

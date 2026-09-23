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

-- Public: the current CWD groups in display order, as plain data for building
-- UIs (pickers, statuslines) without reaching into internals. Each group is
-- { cwd, label, has_current, tabs = {...} }, and each tab is
-- { nr, id, is_current, label, bufnr, path } -- bufnr/path being the tab's
-- active window's buffer and its full name.
function M.groups()
  local groups = build_groups()
  for _, g in ipairs(groups) do
    g.label = group_label(g.cwd)
    for _, t in ipairs(g.tabs) do
      local ok, label = pcall(tab_label, t.id, t.nr)
      t.label = (ok and type(label) == 'string') and label or tostring(t.nr)
      t.bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(t.id))
      t.path = vim.api.nvim_buf_get_name(t.bufnr)
    end
  end
  return groups
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

-- Per-group fold state for the tabline: collapsed[cwd] = true folds a group's
-- tabs behind a "[+N]" count (see M.render / M.toggle_collapse). This is view
-- state only -- the derived group membership is untouched -- and it never
-- persists; prune_collapsed() drops it for groups that cease to exist.
local collapsed = {}

-- Plain (unhighlighted, unescaped) label text for a tab: its number plus buffer
-- basename, or "<n> $cmd" for a terminal. pcall-guarded like tab_label, since
-- window/buffer handles can be briefly invalid during teardown.
local function tab_plain(tab)
  local label = select(2, pcall(tab_label, tab.id, tab.nr))
  return (type(label) == 'string') and label or tostring(tab.nr)
end

-- Force the tabline to re-evaluate its 'tabline' expression. A mapping that
-- changes only cwdtabs' own state -- a same-tab :tcd (gGc) or a fold toggle
-- (gGz) -- alters no buffer content, so nothing repaints on its own;
-- :redrawtabline is the public nudge. Callers may schedule it to run after the
-- triggering command finishes.
local function redraw_tabline()
  vim.cmd('redrawtabline')
end

-- Drop fold state for groups that no longer exist, so a CWD whose tabs all
-- closed doesn't come back pre-folded the next time it's opened.
local function prune_collapsed()
  if next(collapsed) == nil then return end
  local live = {}
  for _, g in ipairs(build_groups()) do live[g.cwd] = true end
  for cwd in pairs(collapsed) do
    if not live[cwd] then collapsed[cwd] = nil end
  end
end

-- Elision markers shown at the edges when tabs are scrolled off (see assemble).
local MARK_L = '‹'
local MARK_R = '›'

-- Serialize a segment { text, hl, tab? } to tabline markup: its highlighted,
-- %-escaped text, wrapped in a %nT click region when it maps to a tab.
local function seg_markup(s)
  if s.tab then
    return '%' .. s.tab .. 'T' .. hl(s.hl) .. esc(s.text) .. '%T'
  end
  return hl(s.hl) .. esc(s.text)
end

-- Assemble the segment list into the final tabline string. The tabline is one
-- physical line, so when the segments are wider than the screen we show a
-- contiguous window that always contains the current tab, rather than letting
-- Neovim truncate it off the right edge. The window is seeded with the current
-- group's "<label> ... <current tab>" so you keep seeing which project you're
-- in, then grown outward into both neighbours; '‹'/'›' mark tabs scrolled off
-- each side. It's derived fresh every render (no stored scroll offset) so it
-- can't drift out of sync, matching the rest of the model.
local function assemble(segs, cur, cur_label)
  local cols = vim.o.columns
  local function wof(s) return vim.fn.strdisplaywidth(s.text) end

  local total = 0
  for _, s in ipairs(segs) do total = total + wof(s) end

  local lo, hi = 1, #segs
  if cur and total > cols then
    lo, hi = cur, cur
    local used = wof(segs[cur])
    -- Seed with the current group's label through the current tab, when that
    -- whole run fits (less 2 cols kept for the markers).
    if cur_label and cur_label < cur then
      local seed = 0
      for k = cur_label, cur do seed = seed + wof(segs[k]) end
      if seed <= cols - 2 then lo, used = cur_label, seed end
    end
    -- Grow outward, right then left, while it fits -- leaving room for the
    -- elision marker that will then be needed on each side.
    local function fits(extra)
      local b = cols - (lo > 1 and 1 or 0) - (hi < #segs and 1 or 0)
      return used + extra <= b
    end
    local grew = true
    while grew do
      grew = false
      if hi < #segs and fits(wof(segs[hi + 1])) then
        hi = hi + 1; used = used + wof(segs[hi]); grew = true
      end
      if lo > 1 and fits(wof(segs[lo - 1])) then
        lo = lo - 1; used = used + wof(segs[lo]); grew = true
      end
    end
  end

  local parts = {}
  if lo > 1 then parts[#parts + 1] = hl('CwdTabsFill') .. MARK_L end
  for k = lo, hi do parts[#parts + 1] = seg_markup(segs[k]) end
  if hi < #segs then parts[#parts + 1] = hl('CwdTabsFill') .. MARK_R end
  -- Fill the rest of the line and make sure no click region dangles.
  parts[#parts + 1] = hl('CwdTabsFill') .. '%T'
  return table.concat(parts)
end

function M.render()
  local ok, out = pcall(function()
    local groups = build_groups()
    local segs = {}       -- { text, hl, tab? } cells, in display order
    local cur, cur_label  -- indices of the current tab cell and its group label

    for gi, group in ipairs(groups) do
      if gi > 1 then
        segs[#segs + 1] = { text = SEP, hl = 'CwdTabsFill' }
      end

      -- Group label, clickable to the group's first tab. The current group's
      -- label is highlighted, and its index is kept so assemble() can keep it
      -- in view when it slices.
      local first = group.tabs[1].nr
      segs[#segs + 1] = {
        text = ' ' .. group_label(group.cwd) .. ':',
        hl = group.has_current and 'CwdTabsGroupSel' or 'CwdTabsGroup',
        tab = first,
      }
      if group.has_current then cur_label = #segs end

      if collapsed[group.cwd] then
        -- Folded: keep the current tab visible (never hide where you are) and
        -- fold the rest into a "[+N]" count; a group you're not in folds to
        -- just its name and count. The count clicks through to the first tab.
        local shown
        for _, tab in ipairs(group.tabs) do
          if tab.is_current then shown = tab break end
        end
        if shown then
          segs[#segs + 1] = { text = ' ' .. tab_plain(shown) .. ' ',
            hl = 'TabLineSel', tab = shown.nr }
          cur = #segs
        end
        local hidden = #group.tabs - (shown and 1 or 0)
        if hidden > 0 then
          local mk = (shown and '' or ' ') .. '[+' .. hidden .. '] '
          segs[#segs + 1] = { text = mk, hl = 'CwdTabsCount', tab = first }
        end
      else
        -- Each tab a native click target selecting that tab.
        for _, tab in ipairs(group.tabs) do
          segs[#segs + 1] = { text = ' ' .. tab_plain(tab) .. ' ',
            hl = tab.is_current and 'TabLineSel' or 'TabLine', tab = tab.nr }
          if tab.is_current then cur = #segs end
        end
      end
    end

    return assemble(segs, cur, cur_label)
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

-- Transient navigation history. focus holds the current and previous group
-- CWDs (for gG<Tab>); last_tab remembers each group's last-active tab so that
-- entering a group returns to where you were, not its first tab. Both live in
-- memory only -- group membership itself stays a pure function of each tab's
-- CWD.
local focus = { current = nil, prev = nil }
local last_tab = {} -- cwd -> last-active tabpage id

-- Record the current tab as its group's last-active tab, and note any group
-- change for gG<Tab>. Called whenever focus settles on a tab.
local function track_focus()
  local id = vim.api.nvim_get_current_tabpage()
  local cwd = tab_cwd(vim.api.nvim_tabpage_get_number(id))
  last_tab[cwd] = id
  if cwd ~= focus.current then
    focus.prev = focus.current
    focus.current = cwd
  end
end

-- The tab to land on when entering the group at `cwd`: its last-active tab if
-- that tab still exists and still belongs to the group, else the group's first
-- tab in tab order. nil if the group has no tabs.
local function group_target_tab(cwd)
  local mru = last_tab[cwd]
  if mru and vim.api.nvim_tabpage_is_valid(mru)
      and tab_cwd(vim.api.nvim_tabpage_get_number(mru)) == cwd then
    return mru
  end
  for _, id in ipairs(vim.api.nvim_list_tabpages()) do
    if tab_cwd(vim.api.nvim_tabpage_get_number(id)) == cwd then
      return id
    end
  end
end

-- Jump to the group `delta` positions from the current tab's group (wrapping
-- around), landing on its last-active tab. Analogous to gt/gT one level up.
-- No-op with fewer than two groups.
local function goto_group(delta)
  local groups = build_groups()
  if #groups < 2 then return end

  local cur_idx
  for i, g in ipairs(groups) do
    if g.has_current then cur_idx = i break end
  end
  if not cur_idx then return end

  local target = (cur_idx - 1 + delta) % #groups + 1
  local id = group_target_tab(groups[target].cwd)
  if id then vim.api.nvim_set_current_tabpage(id) end
end

function M.next_group() goto_group(1) end
function M.prev_group() goto_group(-1) end

-- Return to the previous group's last-active tab, mirroring g<Tab> for tabs.
-- No-op until you have left a group, or if that group no longer has tabs.
function M.last_group()
  if not focus.prev then return end
  local id = group_target_tab(focus.prev)
  if id then vim.api.nvim_set_current_tabpage(id) end
end

-- Tab ids in tabline (display) order: group by group, tabs in tab order within
-- each. This is the spatial left-to-right sequence, which differs from tab
-- number order when groups interleave (native tabs 1:A 2:B 3:A render A[1 3]
-- B[2], so 1's right neighbour is 3, not 2).
local function spatial_order()
  local ids = {}
  for _, g in ipairs(build_groups()) do
    for _, t in ipairs(g.tabs) do ids[#ids + 1] = t.id end
  end
  return ids
end

-- Step to the tab `delta` positions away in tabline order, wrapping -- the
-- spatial counterpart of gt/gT. A count is left to native gt/gT: {count}gt goes
-- to tab *number* {count}, which stays useful because the tabline shows those
-- numbers. Folding is orthogonal -- every tab is still in the sequence, so gt
-- into a folded group surfaces the tab you land on (group skipping is gGt).
local function goto_tab_spatial(delta)
  local count = vim.v.count
  if count > 0 then
    vim.cmd('normal! ' .. count .. (delta > 0 and 'gt' or 'gT'))
    return
  end
  local order = spatial_order()
  if #order < 2 then return end
  local cur = vim.api.nvim_get_current_tabpage()
  local idx
  for i, id in ipairs(order) do
    if id == cur then idx = i break end
  end
  if not idx then
    vim.cmd('normal! ' .. (delta > 0 and 'gt' or 'gT'))
    return
  end
  local target = (idx - 1 + delta) % #order + 1
  vim.api.nvim_set_current_tabpage(order[target])
end

function M.next_tab() goto_tab_spatial(1) end
function M.prev_tab() goto_tab_spatial(-1) end

-- Most-recently-spawned child of `pid` (Linux /proc), or nil. Mirrors how the
-- process-chain walk picks the "active" descendant at each step.
local function proc_last_child(pid)
  local f = io.open('/proc/' .. pid .. '/task/' .. pid .. '/children', 'r')
  if not f then return nil end
  local data = f:read('*a') or ''
  f:close()
  local last
  for c in data:gmatch('%d+') do last = c end
  return last and tonumber(last) or nil
end

-- Live working directory of the shell running in a terminal buffer, for gGc on
-- a terminal. terminal_job_pid is the shell Neovim spawned; its /proc/<pid>/cwd
-- symlink tracks every cd/z, unlike the term:// URL, whose cwd is only where
-- the shell STARTED. We follow the chain to the leaf (a nested shell -- bash in
-- zsh -- is where you're actually navigating), then take the DEEPEST process
-- whose cwd is a directory on THIS host: a containerized leaf (zsh -> docker ->
-- bash) has a cwd in the container's namespace that isn't a real host path, so
-- it's skipped in favor of a host cwd higher up. Linux-only; nil elsewhere or
-- when nothing resolves, so the caller falls back to its no-directory handling.
local function terminal_cwd(bufnr)
  local pid = vim.b[bufnr] and vim.b[bufnr].terminal_job_pid
  if not pid then return nil end
  local chain = { pid }
  for _ = 1, 15 do
    local kid = proc_last_child(chain[#chain])
    if not kid then break end
    chain[#chain + 1] = kid
  end
  for i = #chain, 1, -1 do
    local dir = vim.uv.fs_readlink('/proc/' .. chain[i] .. '/cwd')
    if dir and vim.fn.isdirectory(dir) == 1 then return dir end
  end
  return nil
end

-- :tcd the current tab to the directory of the current buffer, to "recenter"
-- the tab's project context where you are. A terminal uses the live CWD of the
-- shell running in it (see terminal_cwd); a netrw/vim-vinegar listing uses the
-- browsed directory (b:netrw_curdir); a file uses its parent directory. No-op
-- (with a message) for buffers with no resolvable directory ([No Name], or a
-- terminal whose CWD can't be read). The DirChanged autocmd then regroups and
-- redraws the tabline automatically.
function M.tcd_to_buffer()
  local dir
  local netrw = vim.b.netrw_curdir
  if vim.bo.buftype == 'terminal' then
    dir = terminal_cwd(vim.api.nvim_get_current_buf())
    if not dir then
      vim.notify("cwdtabs: can't read the terminal's directory",
        vim.log.levels.WARN)
      return
    end
  -- Use the browsed directory only in a real netrw listing. b:netrw_curdir
  -- lingers on ordinary file buffers reached *through* netrw (still pointing
  -- at the last-browsed dir), so trusting it unconditionally would cd to the
  -- wrong place -- gate it on filetype == 'netrw'.
  elseif vim.bo.filetype == 'netrw' and netrw and netrw ~= '' then
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

-- Toggle the folded state of a tab group (see M.render). With no count, acts on
-- the current tab's group; with a count N (e.g. "3gGz"), acts on the group that
-- tab N belongs to -- a way to name a group, which has no number of its own, by
-- one of its tabs. `count` defaults to v:count, so the mapping needs no arg.
function M.toggle_collapse(count)
  count = count or vim.v.count
  local tabnr
  if count > 0 then
    if count > vim.fn.tabpagenr('$') then
      vim.notify('cwdtabs: no tab ' .. count, vim.log.levels.WARN)
      return
    end
    tabnr = count
  else
    tabnr = vim.fn.tabpagenr()
  end
  local cwd = tab_cwd(tabnr)
  collapsed[cwd] = not collapsed[cwd] or nil
  redraw_tabline()
end

-- Fold every group (like |zM| for folds). The never-hide-current rule still
-- shows the current tab, so you stay oriented -- the tabline shrinks to a row
-- of "name: [+N]" projects with your spot marked in its own group.
function M.fold_all()
  for _, g in ipairs(build_groups()) do
    collapsed[g.cwd] = true
  end
  redraw_tabline()
end

-- Unfold every group (like |zR|): clear all fold state.
function M.unfold_all()
  for cwd in pairs(collapsed) do collapsed[cwd] = nil end
  redraw_tabline()
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
  vim.api.nvim_set_hl(0, 'CwdTabsCount', { link = 'TabLine' })
end

-- Invoke a picker from the optional Telescope layer. Kept behind a lazy require
-- so the core never loads telescope itself: a telescope-less user can still
-- install every mapping/command below; only pressing one reports the missing
-- dependency. The zoxide picker additionally needs the `zoxide` CLI, which it
-- checks and reports on its own.
local function run_picker(name)
  local ok, pickers = pcall(require, 'cwdtabs.pickers')
  if not ok then
    vim.notify('cwdtabs: telescope.nvim is required for the pickers',
      vim.log.levels.WARN)
    return
  end
  pickers[name]()
end

-- <Plug> mappings, created by setup(): the remappable layer for each action.
-- Inert until mapped, so users can bind their own keys without wrapping a Lua
-- function (see cwdtabs-mappings). The default gG* mappings go through these.
local function set_plug_mappings()
  local map = vim.keymap.set
  map('n', '<Plug>(cwdtabs-next-group)', M.next_group,
    { desc = 'cwdtabs: next tab group' })
  map('n', '<Plug>(cwdtabs-prev-group)', M.prev_group,
    { desc = 'cwdtabs: previous tab group' })
  map('n', '<Plug>(cwdtabs-last-group)', M.last_group,
    { desc = 'cwdtabs: last-used tab group' })
  map('n', '<Plug>(cwdtabs-recenter)', M.tcd_to_buffer,
    { desc = 'cwdtabs: recenter tab on buffer dir' })
  map('n', '<Plug>(cwdtabs-toggle-collapse)', M.toggle_collapse,
    { desc = 'cwdtabs: fold/unfold a tab group' })
  map('n', '<Plug>(cwdtabs-fold-all)', M.fold_all,
    { desc = 'cwdtabs: fold all tab groups' })
  map('n', '<Plug>(cwdtabs-unfold-all)', M.unfold_all,
    { desc = 'cwdtabs: unfold all tab groups' })
  map('n', '<Plug>(cwdtabs-next-tab)', M.next_tab,
    { desc = 'cwdtabs: next tab (spatial)' })
  map('n', '<Plug>(cwdtabs-prev-tab)', M.prev_tab,
    { desc = 'cwdtabs: previous tab (spatial)' })
  -- Optional Telescope pickers (see run_picker). The zoxide picker also needs
  -- the zoxide CLI; both degrade to a notice when a dependency is absent.
  map('n', '<Plug>(cwdtabs-pick-zoxide)', function() run_picker('pick_zoxide') end,
    { desc = 'cwdtabs: pick a zoxide dir -> tcd a tab' })
end

-- Installed by setup{ spatial_tab_motions = true }: remap gt/gT to walk the
-- tabline left-to-right instead of by tab number. Independent of the gG*
-- default_keymaps -- it changes built-ins, so it's opt-in on its own.
local function set_spatial_tab_motions()
  local map = vim.keymap.set
  map('n', 'gt', '<Plug>(cwdtabs-next-tab)',
    { remap = true, desc = 'Next tab (spatial)' })
  map('n', 'gT', '<Plug>(cwdtabs-prev-tab)',
    { remap = true, desc = 'Prev tab (spatial)' })
end

-- The mappings installed by setup{ default_keymaps = true }, wiring the gG*
-- "group" prefix to the <Plug> mappings above. remap = true so the <Plug> rhs
-- expands.
local function set_default_keymaps()
  local map = vim.keymap.set
  map('n', 'gGt', '<Plug>(cwdtabs-next-group)',
    { remap = true, desc = 'Next tab group (CWD)' })
  map('n', 'gGT', '<Plug>(cwdtabs-prev-group)',
    { remap = true, desc = 'Prev tab group (CWD)' })
  map('n', 'gG<Tab>', '<Plug>(cwdtabs-last-group)',
    { remap = true, desc = 'Last-used tab group (CWD)' })
  map('n', 'gGc', '<Plug>(cwdtabs-recenter)',
    { remap = true, desc = 'tcd tab to buffer dir' })
  map('n', 'gGz', '<Plug>(cwdtabs-toggle-collapse)',
    { remap = true, desc = 'Fold/unfold tab group (CWD)' })
  map('n', 'gGM', '<Plug>(cwdtabs-fold-all)',
    { remap = true, desc = 'Fold all tab groups (CWD)' })
  map('n', 'gGR', '<Plug>(cwdtabs-unfold-all)',
    { remap = true, desc = 'Unfold all tab groups (CWD)' })
end

-- User commands, created by setup(): thin wrappers over the public functions.
local function set_commands()
  local cmd = vim.api.nvim_create_user_command
  cmd('CwdTabsNext', M.next_group, { desc = 'cwdtabs: next tab group' })
  cmd('CwdTabsPrev', M.prev_group, { desc = 'cwdtabs: previous tab group' })
  cmd('CwdTabsLast', M.last_group, { desc = 'cwdtabs: last-used tab group' })
  cmd('CwdTabsRecenter', M.tcd_to_buffer,
    { desc = 'cwdtabs: recenter tab on buffer dir' })
  cmd('CwdTabsToggleCollapse', function(o) M.toggle_collapse(o.count) end,
    { count = 0, desc = 'cwdtabs: fold/unfold a tab group' })
  cmd('CwdTabsFoldAll', M.fold_all, { desc = 'cwdtabs: fold all tab groups' })
  cmd('CwdTabsUnfoldAll', M.unfold_all,
    { desc = 'cwdtabs: unfold all tab groups' })
  cmd('CwdTabsNextTab', M.next_tab,
    { desc = 'cwdtabs: next tab (spatial)' })
  cmd('CwdTabsPrevTab', M.prev_tab,
    { desc = 'cwdtabs: previous tab (spatial)' })
  -- Optional Telescope pickers (see run_picker); zoxide picker also needs zoxide.
  cmd('CwdTabsPickZoxide', function() run_picker('pick_zoxide') end,
    { desc = 'cwdtabs: pick a zoxide dir -> tcd a tab' })
end

local defaults = {
  default_keymaps = false,     -- install the gG* mappings
  spatial_tab_motions = false, -- remap gt/gT to tabline (spatial) order
}

function M.setup(opts)
  opts = vim.tbl_extend('force', defaults, opts or {})

  set_highlights()
  track_focus() -- seed focus + last_tab for the startup tab

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
      prune_collapsed()
      vim.schedule(redraw_tabline)
    end,
  })

  vim.o.showtabline = 2
  vim.o.tabline = '%!v:lua.require("cwdtabs").render()'

  set_plug_mappings()
  set_commands()
  if opts.default_keymaps then
    set_default_keymaps()
  end
  if opts.spatial_tab_motions then
    set_spatial_tab_motions()
  end
end

return M

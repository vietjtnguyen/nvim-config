-- aaag dashboard: a floating "agents at a glance" window.
--
-- Derived and re-rendered from scratch on every change (like cwdtabs); the only
-- stored view state is per-card fold flags and which card is current. Cards are
-- multi-line, so this is a buffer/float, not a picker list.
--
-- Layout is a grid of fixed-width cells laid into a single buffer: each grid row
-- is as tall as its tallest card, so h/j/k/l map to a clean 2-D matrix (the
-- ragged whitespace that costs is paid back by folding, which makes a card one
-- line). Column count is derived from the window width and `card_width`. Each
-- card has a coloured left gutter bar (colour = attention), its own hanging-
-- indent word-wrap, and the whole current card is highlighted.

local config = require('aaag.config')
local jump = require('aaag.jump')

local M = {}

M.on_refresh = nil

local ns = vim.api.nvim_create_namespace('aaag')
local ns_sel = vim.api.nvim_create_namespace('aaag_sel')
local state = {
  buf = nil,
  win = nil,
  cards = {},
  collapsed = {},   -- sid -> true when folded
  rects = {},       -- sid -> { gr, gc, lines = { {line, c0, c1} ... } }
  grid = {},        -- gr -> { gc -> sid }
  current = nil,    -- sid of the selected card
  pinned = false,   -- true once the user has chosen a card (stops auto-select)
  suppress = false, -- guard so our own cursor moves don't count as user nav
}

local GUTTER = '│'
local GLEN = #GUTTER

local GLYPH = {
  blocked = { '▲', 'AaagBlocked' },
  busy    = { '●', 'AaagBusy' },
  idle    = { '●', 'AaagIdle' },
  stale   = { '○', 'AaagStale' },
  closed  = { '✓', 'AaagClosed' },
  loading = { '…', 'AaagStale' },
}

local FIELDS = {
  { 'thread', 'Thread:' },
  { 'now', 'Now:' },
  { 'last', 'Last from me:' },
  { 'state', 'State:' },
  { 'arc', 'Arc:' },
}
local LABEL_W = 14

function M.set_highlights()
  local function hl(name, opts) vim.api.nvim_set_hl(0, name, opts) end
  hl('AaagBlocked', { link = 'DiagnosticWarn', default = true })
  hl('AaagBusy', { link = 'DiagnosticOk', default = true })
  hl('AaagIdle', { link = 'Function', default = true })
  hl('AaagStale', { link = 'Comment', default = true })
  hl('AaagClosed', { link = 'Comment', default = true })
  hl('AaagName', { link = 'Title', default = true })
  hl('AaagLabel', { link = 'Comment', default = true })
  hl('AaagMeta', { link = 'NonText', default = true })
  hl('AaagSelect', { link = 'CursorLine', default = true })
  hl('AaagBorder', { link = 'WinSeparator', default = true })
end

-- Greedy word-wrap `content` to display `width`, prefixing the first line with
-- `first_prefix` and the rest with `cont_prefix`. An over-wide single word is
-- left to overflow (rare -- long paths are shortened before they get here).
local function wrap(content, first_prefix, cont_prefix, width)
  local out, line, prefix = {}, first_prefix, first_prefix
  local col, started = vim.fn.strdisplaywidth(prefix), false
  for word in content:gmatch('%S+') do
    local w = vim.fn.strdisplaywidth(word)
    if not started then
      line = prefix .. word; col = col + w; started = true
    elseif col + 1 + w <= width then
      line = line .. ' ' .. word; col = col + 1 + w
    else
      out[#out + 1] = line
      prefix = cont_prefix
      line = prefix .. word
      col = vim.fn.strdisplaywidth(prefix) + w
    end
  end
  out[#out + 1] = line
  return out
end

-- Truncate to display width `w`, appending '…'.
local function trunc(text, w)
  if vim.fn.strdisplaywidth(text) <= w then return text end
  local n = vim.fn.strchars(text)
  while n > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, n) .. '…') > w do
    n = n - 1
  end
  return vim.fn.strcharpart(text, 0, n) .. '…'
end

-- Keep the tail of `text` (informative end of a path) within display width `w`.
local function shorten_left(text, w)
  if vim.fn.strdisplaywidth(text) <= w then return text end
  local n, start = vim.fn.strchars(text), 0
  while start < n
      and vim.fn.strdisplaywidth('…' .. vim.fn.strcharpart(text, start)) > w do
    start = start + 1
  end
  return '…' .. vim.fn.strcharpart(text, start)
end

-- Render one card into a list of cell lines (each padded to display width `cw`)
-- plus cell-relative highlight spans {line, c0, c1, hl}. c1 == -1 means "to end
-- of this cell line".
local function make_cell(card, cw)
  local clines, cspans = {}, {}
  local function push(text, ghl)
    local dw = vim.fn.strdisplaywidth(text)
    if dw < cw then text = text .. string.rep(' ', cw - dw) end
    clines[#clines + 1] = text
    if ghl and text:sub(1, GLEN) == GUTTER then
      cspans[#cspans + 1] = { line = #clines, c0 = 0, c1 = GLEN, hl = ghl }
    end
    return #clines
  end
  local function push_wrapped(content, first_prefix, cont_prefix, ghl, on_first)
    for i, l in ipairs(wrap(content, first_prefix, cont_prefix, cw)) do
      local ln = push(l, ghl)
      if i == 1 and on_first then on_first(ln) end
    end
  end

  local folded = state.collapsed[card.sid]
  local g = GLYPH[card.attention] or GLYPH.idle
  local ghl = g[2]
  local arrow = folded and '▸' or '▾'
  local age = card.last_ago and ('last ' .. card.last_ago) or ''

  -- Header (single line, truncated to fit): gutter, fold arrow, glyph, name,
  -- [attention], age; when folded, the thread trails so a folded card still says
  -- what it is.
  local head = string.format('%s %s %s %s  [%s]  %s',
    GUTTER, arrow, g[1], card.name, card.attention, age)
  if folded and card.fields.thread then head = head .. '  — ' .. card.fields.thread end
  local hln = push(trunc(head, cw), ghl)
  local ncol = #(GUTTER .. ' ' .. arrow .. ' ' .. g[1] .. ' ')
  cspans[#cspans + 1] = { line = hln, c0 = ncol, c1 = ncol + #card.name, hl = 'AaagName' }

  if not folded then
    local cwd = card.cwd:gsub('^' .. vim.pesc(vim.env.HOME or ''), '~')
    local cln = push(GUTTER .. ' ' .. shorten_left(cwd, cw - GLEN - 1), ghl)
    cspans[#cspans + 1] = { line = cln, c0 = GLEN, c1 = -1, hl = 'AaagMeta' }
    if card.meta_line then
      push_wrapped(card.meta_line, GUTTER .. ' ', GUTTER .. '   ', ghl, function(ln)
        cspans[#cspans + 1] = { line = ln, c0 = GLEN, c1 = -1, hl = 'AaagMeta' }
      end)
    end
    for _, f in ipairs(FIELDS) do
      local val = card.fields[f[1]]
      if not val and card.loading then val = '…' end
      if val and val ~= '' then
        local first = GUTTER .. ' ' .. f[2] .. string.rep(' ', LABEL_W - #f[2])
        local cont = GUTTER .. ' ' .. string.rep(' ', LABEL_W)
        push_wrapped(val, first, cont, ghl, function(ln)
          cspans[#cspans + 1] =
            { line = ln, c0 = GLEN + 1, c1 = GLEN + 1 + #f[2], hl = 'AaagLabel' }
        end)
      end
    end
  end
  return clines, cspans
end

-- Choose the column count and cell width for an inner window width.
local function layout(w)
  local sep = config.opts.col_sep
  local n
  if type(config.opts.columns) == 'number' then
    n = config.opts.columns
  else
    n = math.floor((w + sep) / (config.opts.card_width + sep))
  end
  n = math.max(1, math.min(n, config.opts.max_columns, #state.cards))
  local cw = math.floor((w - (n - 1) * sep) / n)
  while n > 1 and cw < 30 do
    n = n - 1
    cw = math.floor((w - (n - 1) * sep) / n)
  end
  return n, cw
end

-- Build all buffer lines + highlight spans for the grid, and (re)populate rects
-- and grid for navigation/selection.
local function build(width)
  state.rects, state.grid = {}, {}
  local lines, hls = {}, {}
  if #state.cards == 0 then
    return { '', '   No live Claude Code sessions.' }, {}
  end

  local n, cw = layout(width)
  -- Column gap: a centred vertical rule (' │ ') when enabled and multi-column,
  -- else plain spaces. bar_off is the byte offset of the rule within the gap.
  local rule = config.opts.column_rule and n > 1
  local sep = rule and ' │ ' or string.rep(' ', config.opts.col_sep)
  local bar_off = rule and 1 or nil

  -- Pre-render every cell.
  local cells = {}
  for _, card in ipairs(state.cards) do
    local cl, cs = make_cell(card, cw)
    cells[#cells + 1] = { sid = card.sid, lines = cl, spans = cs }
  end

  local gr = 0
  for i = 1, #cells, n do
    gr = gr + 1
    state.grid[gr] = {}
    local rowh = 0
    for gc = 1, n do
      local cell = cells[i + gc - 1]
      if cell then rowh = math.max(rowh, #cell.lines) end
    end
    local base = #lines
    for r = 1, rowh do
      local segs, xoff = {}, 0
      for gc = 1, n do
        local cell = cells[i + gc - 1]
        local text = (cell and cell.lines[r]) or string.rep(' ', cw)
        if cell and cell.lines[r] then
          local rect = state.rects[cell.sid]
          if not rect then
            rect = { gr = gr, gc = gc, lines = {} }
            state.rects[cell.sid] = rect
            state.grid[gr][gc] = cell.sid
          end
          rect.lines[#rect.lines + 1] = { line = base + r, c0 = xoff, c1 = xoff + #text }
          for _, sp in ipairs(cell.spans) do
            if sp.line == r then
              local c1 = (sp.c1 == -1) and (xoff + #text) or (xoff + sp.c1)
              hls[#hls + 1] = { line = base + r, c0 = xoff + sp.c0, c1 = c1, hl = sp.hl }
            end
          end
        end
        segs[#segs + 1] = text
        xoff = xoff + #text
        if gc < n then
          if bar_off then
            hls[#hls + 1] = { line = base + r, c0 = xoff + bar_off,
              c1 = xoff + bar_off + GLEN, hl = 'AaagBorder' }
          end
          segs[#segs + 1] = sep
          xoff = xoff + #sep
        end
      end
      lines[#lines + 1] = table.concat(segs)
    end
    lines[#lines + 1] = '' -- separator row between grid rows
  end
  return lines, hls
end

local function paint_selection()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  vim.api.nvim_buf_clear_namespace(state.buf, ns_sel, 0, -1)
  local rect = state.current and state.rects[state.current]
  if not rect then return end
  for _, ln in ipairs(rect.lines) do
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns_sel, ln.line - 1, ln.c0,
      { end_col = ln.c1, hl_group = 'AaagSelect' })
  end
end

local function place_cursor()
  local rect = state.current and state.rects[state.current]
  if rect and rect.lines[1] then
    state.suppress = true -- our own move; the CursorMoved handler ignores it
    pcall(vim.api.nvim_win_set_cursor, state.win, { rect.lines[1].line, rect.lines[1].c0 })
  end
end

-- Which card contains the cursor (byte-accurate over each card's own spans).
local function locate(line, col)
  for sid, rect in pairs(state.rects) do
    for _, ln in ipairs(rect.lines) do
      if ln.line == line and col >= ln.c0 and col < ln.c1 then return sid end
    end
  end
end

local function redraw()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  local lines, hls = build(vim.api.nvim_win_get_width(state.win))
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, h.line - 1, h.c0,
      { end_col = h.c1, hl_group = h.hl })
  end
  -- Until the user picks a card, keep the selection on the top-left (highest-
  -- priority after sort) so it tracks what most needs attention as data lands.
  if not state.pinned or not state.rects[state.current] then
    state.current = state.grid[1] and state.grid[1][1]
  end
  place_cursor()
  paint_selection()
end

local function card_by_sid(sid)
  for _, c in ipairs(state.cards) do if c.sid == sid then return c end end
end

-- Grid move by (dr, dc). Columns clamp to the last populated cell in a row so a
-- partial final row is still reachable.
local function move(dr, dc)
  local rect = state.current and state.rects[state.current]
  if not rect then return end
  local gr, gc = rect.gr + dr, rect.gc + dc
  local row = state.grid[gr]
  if not row then return end
  local sid = row[gc]
  if not sid then
    for c = gc, 1, -1 do if row[c] then sid = row[c] break end end
  end
  if sid then
    state.current = sid
    state.pinned = true
    place_cursor()
    paint_selection()
  end
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function set_keymaps()
  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = state.buf, nowait = true })
  end
  map('q', M.close)
  map('<Esc>', M.close)
  map('j', function() move(1, 0) end)
  map('<Down>', function() move(1, 0) end)
  map('k', function() move(-1, 0) end)
  map('<Up>', function() move(-1, 0) end)
  map('h', function() move(0, -1) end)
  map('<Left>', function() move(0, -1) end)
  map('l', function() move(0, 1) end)
  map('<Right>', function() move(0, 1) end)
  map('<CR>', function()
    local card = state.current and card_by_sid(state.current)
    if not card then return end
    M.close()
    if not jump.to_pid(card.pid) then
      vim.notify('aaag: ' .. card.name ..
        ' is not in a visible nvim terminal (tmux/external?)', vim.log.levels.WARN)
    end
  end)
  local function toggle()
    if state.current then
      state.collapsed[state.current] = not state.collapsed[state.current]
      redraw()
    end
  end
  map('<Tab>', toggle)
  map('za', toggle)
  map('zM', function()
    for _, c in ipairs(state.cards) do state.collapsed[c.sid] = true end
    redraw()
  end)
  map('zR', function()
    -- Set every card explicitly expanded; clearing the table to {} would let
    -- seed_folds re-seed nil entries back to their defaults on the next update.
    for _, c in ipairs(state.cards) do state.collapsed[c.sid] = false end
    redraw()
  end)
  map('r', function() if M.on_refresh then M.on_refresh() end end)

  -- Keep the selection in sync when the cursor is moved by anything other than
  -- our grid keys (mouse, gg, search).
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = state.buf,
    callback = function()
      if state.suppress then state.suppress = false; return end
      local pos = vim.api.nvim_win_get_cursor(state.win)
      local sid = locate(pos[1], pos[2])
      if sid and sid ~= state.current then
        state.current = sid
        state.pinned = true
        paint_selection()
      end
    end,
  })
end

local function seed_folds()
  local mode = config.opts.fold_default
  for _, c in ipairs(state.cards) do
    if state.collapsed[c.sid] == nil then
      if mode == 'collapsed' then
        state.collapsed[c.sid] = true
      elseif mode == 'blocked' then
        state.collapsed[c.sid] = (c.attention ~= 'blocked')
      else
        state.collapsed[c.sid] = false
      end
    end
  end
end

-- Float geometry from the current editor size (shared by open and resize).
local function win_geometry()
  local w = math.max(40, math.floor(vim.o.columns * config.opts.width_frac))
  local h = math.max(8, math.floor(vim.o.lines * config.opts.height_frac))
  return {
    relative = 'editor',
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    border = 'rounded',
    title = ' aaag — agents at a glance ',
    title_pos = 'center',
  }
end

function M.open(cards)
  state.cards = cards
  seed_folds()
  if M.is_open() then return redraw() end

  -- Fresh open: let the selection auto-track the top-left until the user navigates.
  state.pinned = false
  state.current = nil

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].filetype = 'aaag'
  vim.bo[state.buf].bufhidden = 'wipe'

  local cfg = win_geometry()
  cfg.style = 'minimal' -- 'style' is an open-only field, not valid for set_config
  state.win = vim.api.nvim_open_win(state.buf, true, cfg)
  vim.wo[state.win].wrap = false
  vim.wo[state.win].cursorline = false
  set_keymaps()

  -- Re-fit the float and recompute the column count when the editor is resized.
  vim.api.nvim_create_autocmd('VimResized', {
    group = vim.api.nvim_create_augroup('aaag_win', { clear = true }),
    callback = function()
      if not M.is_open() then return end
      pcall(vim.api.nvim_win_set_config, state.win, win_geometry())
      redraw()
    end,
  })

  redraw()
end

function M.update(cards)
  if not M.is_open() then return end
  state.cards = cards
  seed_folds()
  redraw()
end

return M

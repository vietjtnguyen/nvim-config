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

M.on_refresh = nil          -- refresh all cards (mtime-cached)
M.on_refresh_card = nil     -- re-prompt one card by sid
M.on_toggle_dormant = nil   -- reveal/hide the dormant section
M.on_delete_card = nil      -- delete one dormant conversation by sid

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
  set_pos = nil,    -- last cursor position WE set, matched (not a boolean flag)
                    -- to ignore it in CursorMoved: an API move may not fire the
                    -- event, so a boolean guard would swallow the next real move
  show_dormant = false, -- whether the dormant section is revealed
}

local GUTTER = '│'
local GLEN = #GUTTER -- byte length (offsets/highlights are byte-based)
local GLEN_DISP = vim.fn.strdisplaywidth(GUTTER) -- display cells (1) for layout math

-- Braille spinner shown on a card while it is loading or being refreshed.
local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local spin_idx = 1
local spin_timer = nil

local GLYPH = {
  blocked = { '▲', 'AaagBlocked' },
  busy    = { '●', 'AaagBusy' },
  idle    = { '●', 'AaagIdle' },
  stale   = { '○', 'AaagStale' },
  closed  = { '✓', 'AaagClosed' },
  dormant = { '○', 'AaagDormant' },
  loading = { '…', 'AaagStale' },
}
-- Left gutter bar: solid for a live conversation, dashed for a dormant one.
local BAR_ACTIVE = '│'
local BAR_DORMANT = '╎'

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
  hl('AaagDormant', { link = 'Directory', default = true })
  hl('AaagName', { link = 'Title', default = true })
  hl('AaagLabel', { link = 'Comment', default = true })
  hl('AaagMeta', { link = 'NonText', default = true })
  hl('AaagError', { link = 'DiagnosticWarn', default = true })
  hl('AaagSelect', { link = 'CursorLine', default = true })
  hl('AaagBorder', { link = 'WinSeparator', default = true })
end

-- Break a single token wider than `budget` display cells into chunks that each
-- fit, on character boundaries. A generated path/URL/hash has no spaces to wrap
-- at, so without this it would overflow the fixed-width cell and shove later
-- grid columns off the right edge (window wrap is off).
local function hard_split(word, budget)
  local out, rest = {}, word
  while vim.fn.strdisplaywidth(rest) > budget do
    local n = vim.fn.strchars(rest)
    while n > 1 and vim.fn.strdisplaywidth(vim.fn.strcharpart(rest, 0, n)) > budget do
      n = n - 1
    end
    out[#out + 1] = vim.fn.strcharpart(rest, 0, n)
    rest = vim.fn.strcharpart(rest, n)
  end
  out[#out + 1] = rest
  return out
end

-- Greedy word-wrap `content` to display `width`, prefixing the first line with
-- `first_prefix` and the rest with `cont_prefix`. A word wider than the line
-- budget is hard-split so every emitted line fits `width`.
local function wrap(content, first_prefix, cont_prefix, width)
  local out, prefix, line = {}, first_prefix, nil
  local col = 0
  -- Split over-wide tokens by the continuation budget (the smaller of the two
  -- prefixes' budgets), so a chunk placed on either a first or continuation line
  -- still fits.
  local split_budget = math.max(1, width - vim.fn.strdisplaywidth(cont_prefix))
  for word in content:gmatch('%S+') do
    local w = vim.fn.strdisplaywidth(word)
    if line and col + 1 + w <= width then
      line = line .. ' ' .. word; col = col + 1 + w
    elseif not line and w <= width - vim.fn.strdisplaywidth(prefix) then
      line = prefix .. word; col = vim.fn.strdisplaywidth(prefix) + w
    elseif w <= split_budget then
      if line then out[#out + 1] = line end
      prefix = cont_prefix
      line = prefix .. word; col = vim.fn.strdisplaywidth(prefix) + w
    else
      if line then out[#out + 1] = line; line = nil end
      for _, chunk in ipairs(hard_split(word, split_budget)) do
        out[#out + 1] = prefix .. chunk
        prefix = cont_prefix
      end
    end
  end
  if line then out[#out + 1] = line end
  if #out == 0 then out[#out + 1] = first_prefix end
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
  local bar = card.active and BAR_ACTIVE or BAR_DORMANT
  local clines, cspans = {}, {}
  local function push(text, ghl)
    -- Guarantee the cell fits its width both ways: truncate an over-wide line
    -- (safety net -- wrap() already fits), pad a short one to keep the grid square.
    if vim.fn.strdisplaywidth(text) > cw then text = trunc(text, cw) end
    local dw = vim.fn.strdisplaywidth(text)
    if dw < cw then text = text .. string.rep(' ', cw - dw) end
    clines[#clines + 1] = text
    if ghl and text:sub(1, GLEN) == bar then
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
  local arrow = folded and '►' or '▼'
  local age = card.last_ago and ('last ' .. card.last_ago) or ''

  -- Header (one line, truncated to fit): bar, fold arrow, glyph, name, [state],
  -- age; folded, a snippet (thread or first message) trails so a collapsed card
  -- still says what it is. The glyph slot becomes the spinner while loading: a
  -- fixed one-column slot near the start, so a long title never hides it and the
  -- name doesn't shift.
  local spinning = card.refreshing or card.loading
  local glyph = spinning and SPINNER[spin_idx] or g[1]
  local head = string.format('%s %s %s %s  [%s]  %s',
    bar, arrow, glyph, card.name, card.attention, age)
  local snippet = card.fields.thread or card.first
  if folded and snippet then head = head .. '  — ' .. snippet end
  local text = trunc(head, cw)
  local hln = push(text, ghl)
  local gcol = #(bar .. ' ' .. arrow .. ' ')
  if spinning then
    cspans[#cspans + 1] = { line = hln, c0 = gcol, c1 = gcol + #glyph, hl = 'AaagBusy' }
  end
  local ncol = gcol + #glyph + 1
  cspans[#cspans + 1] = { line = hln, c0 = ncol, c1 = ncol + #card.name, hl = 'AaagName' }

  if not folded then
    local cwd = (card.cwd or ''):gsub('^' .. vim.pesc(vim.env.HOME or ''), '~')
    local cln = push(bar .. ' ' .. shorten_left(cwd, cw - GLEN - 1), ghl)
    cspans[#cspans + 1] = { line = cln, c0 = GLEN, c1 = -1, hl = 'AaagMeta' }
    if card.meta_line then
      push_wrapped(card.meta_line, bar .. ' ', bar .. '   ', ghl, function(ln)
        cspans[#cspans + 1] = { line = ln, c0 = GLEN, c1 = -1, hl = 'AaagMeta' }
      end)
    end
    if card.error then
      push_wrapped(card.error, bar .. ' ', bar .. '   ', ghl, function(ln)
        cspans[#cspans + 1] = { line = ln, c0 = GLEN, c1 = -1, hl = 'AaagError' }
      end)
    end
    for _, f in ipairs(FIELDS) do
      local val = card.fields[f[1]]
      if not val and card.loading then val = '…' end
      if val and val ~= '' then
        local first = bar .. ' ' .. f[2] .. string.rep(' ', LABEL_W - #f[2])
        local cont = bar .. ' ' .. string.rep(' ', LABEL_W)
        push_wrapped(val, first, cont, ghl, function(ln)
          cspans[#cspans + 1] =
            { line = ln, c0 = GLEN + 1, c1 = GLEN + 1 + #f[2], hl = 'AaagLabel' }
        end)
      end
    end
  end

  -- A dormant (not-live) conversation recedes: dim every line's content after
  -- the bar (the bar keeps its dormant/closed colour). Added last so it wins at
  -- equal extmark priority. Live cards -- including closed ones -- stay bright;
  -- closedness is shown by the ✓ glyph, not by dimming.
  if not card.active then
    for i = 1, #clines do
      cspans[#cspans + 1] = { line = i, c0 = GLEN, c1 = -1, hl = 'AaagClosed' }
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
-- and grid for navigation/selection. Live cards fill the top block, dormant
-- cards a second block below a labeled rule; grid rows are numbered continuously
-- across both so h/j/k/l crosses the break.
local function build(width)
  state.rects, state.grid = {}, {}
  local lines, hls = {}, {}
  if #state.cards == 0 then
    return { '', '   No conversations found.' }, {}
  end

  local n, cw = layout(width)
  -- Column gap: a vertical rule centred in a `col_sep`-cell gap when enabled and
  -- multi-column, else plain spaces. bar_off is the rule's byte offset within the
  -- gap (leading spaces are one byte each, so it equals the left-space count).
  local rule = config.opts.column_rule and n > 1
  local sep, bar_off
  if rule then
    local left = math.floor((config.opts.col_sep - GLEN_DISP) / 2)
    if left < 0 then left = 0 end
    local right = math.max(0, config.opts.col_sep - GLEN_DISP - left)
    sep = string.rep(' ', left) .. GUTTER .. string.rep(' ', right)
    bar_off = left
  else
    sep = string.rep(' ', config.opts.col_sep)
  end

  -- Split cards into live and dormant (state.cards is already sorted live-first,
  -- then dormant by recency). Dormant cells are only built when the section is
  -- revealed.
  local active_cards, dormant_cards = {}, {}
  for _, card in ipairs(state.cards) do
    if card.active then active_cards[#active_cards + 1] = card
    else dormant_cards[#dormant_cards + 1] = card end
  end
  local function cells_of(cards)
    local out = {}
    for _, card in ipairs(cards) do
      local cl, cs = make_cell(card, cw)
      out[#out + 1] = { sid = card.sid, lines = cl, spans = cs }
    end
    return out
  end

  local gr = 0
  local function lay(cells)
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
      lines[#lines + 1] = '' -- blank row between grid rows
    end
  end

  if config.opts.show_help then
    local help = trunc(' h/j/k/l move · zo/zc/za expand/collapse/toggle · '
      .. '<Tab> show/hide dormant · <CR> open · C-x/v/t split · '
      .. 'r refresh · R refresh all · D delete · q close', width)
    lines[#lines + 1] = help
    hls[#hls + 1] = { line = #lines, c0 = 0, c1 = #help, hl = 'AaagMeta' }
    lines[#lines + 1] = ''
  end

  lay(cells_of(active_cards))
  if #dormant_cards > 0 then
    if state.show_dormant then
      if #active_cards > 0 then
        local label = '── recent '
        label = label .. string.rep('─', math.max(0, width - vim.fn.strdisplaywidth(label)))
        lines[#lines + 1] = label
        hls[#hls + 1] = { line = #lines, c0 = 0, c1 = #label, hl = 'AaagBorder' }
        lines[#lines + 1] = ''
      end
      lay(cells_of(dormant_cards))
    else
      -- Hidden: a single hint line with the count and how to reveal.
      local hint = string.format('── %d dormant · <Tab> to show ', #dormant_cards)
      hint = hint .. string.rep('─', math.max(0, width - vim.fn.strdisplaywidth(hint)))
      lines[#lines + 1] = hint
      hls[#hls + 1] = { line = #lines, c0 = 0, c1 = #hint, hl = 'AaagBorder' }
    end
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
    local pos = { rect.lines[1].line, rect.lines[1].c0 }
    state.set_pos = pos -- our own move; CursorMoved ignores this exact position
    pcall(vim.api.nvim_win_set_cursor, state.win, pos)
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

-- Move the selection to a specific card by sid (used after a delete to land on
-- an adjacent card rather than resetting to the top). No-op if it isn't shown.
function M.select(sid)
  if not (sid and state.rects[sid]) then return end
  state.current = sid
  state.pinned = true
  place_cursor()
  paint_selection()
end

-- Spinner animation: run a repeating timer only while some card is loading or
-- refreshing, advancing the frame and redrawing; stop it as soon as nothing is
-- active (or the dashboard closes).
local function any_active()
  for _, c in ipairs(state.cards) do
    if c.refreshing or c.loading then return true end
  end
  return false
end

local function stop_spinner()
  if spin_timer then
    vim.fn.timer_stop(spin_timer)
    spin_timer = nil
  end
end

local function tick()
  if not M.is_open() or not any_active() then return stop_spinner() end
  spin_idx = spin_idx % #SPINNER + 1
  redraw()
end

local function ensure_spinner()
  if not spin_timer and M.is_open() and any_active() then
    spin_timer = vim.fn.timer_start(90, tick, { ['repeat'] = -1 })
  end
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
  stop_spinner()
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
    if card.active then
      -- Live: jump to the terminal tab already running it.
      if not jump.to_pid(card.pid) then
        vim.notify('aaag: ' .. card.name ..
          ' is not in a visible nvim terminal (tmux/external?)', vim.log.levels.WARN)
      end
    else
      -- Dormant: resume it in a new tab, tcd'd to its work dir.
      jump.resume('tab', card.cwd, card.sid)
    end
  end)
  -- Telescope-style open keys: resume the card in a split/vsplit/new tab. These
  -- always resume (even a live card starts a fresh copy), matching the picker.
  local function open_in(mode)
    local card = state.current and card_by_sid(state.current)
    if not card then return end
    M.close()
    jump.resume(mode, card.cwd, card.sid)
  end
  map('<C-x>', function() open_in('split') end)
  map('<C-v>', function() open_in('vsplit') end)
  map('<C-t>', function() open_in('tab') end)
  local function toggle()
    if state.current then
      state.collapsed[state.current] = not state.collapsed[state.current]
      redraw()
    end
  end
  -- Standard vim fold keys, applied to the selected card.
  map('za', toggle)
  map('zo', function()
    if state.current then state.collapsed[state.current] = false; redraw() end
  end)
  map('zc', function()
    if state.current then state.collapsed[state.current] = true; redraw() end
  end)
  -- <Tab> reveals/hides the dormant section (init reloads it on reveal).
  map('<Tab>', function()
    if M.on_toggle_dormant then M.on_toggle_dormant() end
  end)
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
  map('r', function()
    if not state.current then return end
    -- Expand the card so the summary you're loading becomes visible.
    state.collapsed[state.current] = false
    redraw()
    if M.on_refresh_card then M.on_refresh_card(state.current) end
  end)
  map('R', function() if M.on_refresh then M.on_refresh() end end)
  map('D', function()
    local card = state.current and card_by_sid(state.current)
    if not card then return end
    if card.active then
      vim.notify('aaag: refusing to delete a live conversation', vim.log.levels.WARN)
      return
    end
    -- Full detail so it's clear exactly what's being removed.
    local info = {
      'Permanently delete this conversation and its transcript?',
      '',
      'Name:  ' .. (card.name or '?'),
      'State: ' .. (card.attention or '?')
        .. (card.last_ago and ('  ·  last active ' .. card.last_ago) or ''),
      'CWD:   ' .. (card.cwd or '?'),
      'SID:   ' .. card.sid,
      'File:  ' .. (card.transcript or '?'),
    }
    local any_field = false
    for _, f in ipairs(FIELDS) do
      local v = card.fields[f[1]]
      if v and v ~= '' then
        info[#info + 1] = f[2] .. ' ' .. v
        any_field = true
      end
    end
    if not any_field and card.first then info[#info + 1] = 'First: ' .. card.first end
    -- &Yes -> Y confirms; N/Esc/Ctrl-C all cancel (pcall swallows the interrupt
    -- so it exits the prompt gracefully instead of erroring).
    local ok, choice = pcall(vim.fn.confirm, table.concat(info, '\n'), '&Yes\n&No', 2)
    if ok and choice == 1 and M.on_delete_card then M.on_delete_card(card.sid) end
  end)

  -- Keep the selection in sync when the cursor is moved by anything other than
  -- our grid keys (mouse, gg, search).
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = state.buf,
    callback = function()
      local pos = vim.api.nvim_win_get_cursor(state.win)
      if state.set_pos and pos[1] == state.set_pos[1] and pos[2] == state.set_pos[2] then
        return -- our own programmatic move, not user navigation
      end
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
  for _, c in ipairs(state.cards) do
    if state.collapsed[c.sid] == nil then
      -- Live cards follow fold_default; dormant cards follow their own default
      -- (collapsed) so the recency tail stays scannable.
      local mode = c.active and config.opts.fold_default
        or config.opts.dormant_fold_default
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

function M.open(cards, show_dormant)
  state.cards = cards
  state.show_dormant = show_dormant or false
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
  ensure_spinner()

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

function M.update(cards, show_dormant)
  if not M.is_open() then return end
  state.cards = cards
  if show_dormant ~= nil then state.show_dormant = show_dormant end
  seed_folds()
  redraw()
  ensure_spinner()
end

return M

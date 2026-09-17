-- aaag: agents at a glance.
--
-- A quicklook dashboard over the Claude Code CLI sessions you already have
-- running in Neovim terminal tabs. It observes -- it does not launch, own, or
-- orchestrate them: everything is derived from Claude Code's own on-disk state
-- (live-session metadata + transcripts) plus Neovim's terminal process info.
-- Delete this plugin and your sessions and terminals are untouched.
--
-- Pipeline: discovery (live sessions) -> transcript (deterministic age/tail) ->
-- recap (async A/B model summaries) -> ui (folding float). Each card fills in
-- progressively: deterministic fields immediately, prose as summaries land.

local config = require('aaag.config')
local discovery = require('aaag.discovery')
local transcript = require('aaag.transcript')
local recap = require('aaag.recap')
local ui = require('aaag.ui')

local M = {}

-- The current cards, kept as stable objects (keyed by sid) so async callbacks
-- mutate the same card the UI is showing. Derived, never persisted.
M._cards = {}

-- Whether the dormant section is revealed (hidden by default; <Tab> toggles).
M._show_dormant = false

-- Display priority: what needs your attention sorts to the top, what's done or
-- forgotten sinks to the bottom.
local PRIORITY = {
  blocked = 1, busy = 2, loading = 3, idle = 3, stale = 4, closed = 5,
}

-- A session is "blocked" (waiting on YOU) rather than merely idle when its state
-- line both mentions waiting and names something that needs your input. This is
-- a heuristic over the model's prose -- Claude's own idle/busy status can't tell
-- "asked you a question" from "finished cleanly".
local BLOCK_HINTS = {
  'decid', 'decision', 'choose', 'which', 'your call', 'approv', 'confirm',
  'question', 'direction', 'input', 'clarif', 'waiting on you',
}

local function is_blocked(state_text)
  if not state_text:find('wait', 1, true) then return false end
  for _, h in ipairs(BLOCK_HINTS) do
    if state_text:find(h, 1, true) then return true end
  end
  return false
end

local function recompute_attention(card)
  -- Dormant (not-live) cards split only into closed vs generic dormant; the
  -- closed distinction is only known once a summary has been generated.
  if not card.active then
    local s = (card.fields.state or ''):lower()
    if s:find('closed', 1, true) or s:find('write off', 1, true) then
      card.attention = 'closed'
    else
      card.attention = 'dormant'
    end
    return
  end
  local s = (card.fields.state or ''):lower()
  local stale = card.last_epoch
    and (os.time() - card.last_epoch) > config.opts.stale_days * 86400
  if s:find('closed', 1, true) or s:find('write off', 1, true) then
    card.attention = 'closed'
  elseif card.status == 'busy' then
    card.attention = 'busy'
  elseif card.loading then
    card.attention = stale and 'stale' or 'loading'
  elseif is_blocked(s) then
    card.attention = 'blocked'
  elseif stale then
    card.attention = 'stale'
  else
    card.attention = 'idle'
  end
end

-- Live cards first (by attention priority, then recency), then dormant cards by
-- recency. The UI draws the active/dormant break where card.active flips.
local function sorted()
  local active, dormant = {}, {}
  for _, c in ipairs(M._cards) do
    if c.active then active[#active + 1] = c else dormant[#dormant + 1] = c end
  end
  table.sort(active, function(a, b)
    local pa = PRIORITY[a.attention] or 3
    local pb = PRIORITY[b.attention] or 3
    if pa ~= pb then return pa < pb end
    return (a.last_epoch or 0) > (b.last_epoch or 0)
  end)
  table.sort(dormant, function(a, b) return (a.last_epoch or 0) > (b.last_epoch or 0) end)
  local out = {}
  for _, c in ipairs(active) do out[#out + 1] = c end
  for _, c in ipairs(dormant) do out[#out + 1] = c end
  return out
end

-- Push the current cards to the UI (with the dormant-visibility flag).
local function render()
  ui.update(sorted(), M._show_dormant)
end

-- A dormant conversation is summarized only if it was active within the last 24
-- hours; older ones stay deterministic (cheap head metadata) until `r`.
local function summarize_recent(mtime)
  return mtime ~= nil and (os.time() - mtime) < 86400
end

-- Live cards always summarize; a dormant card only when the section is revealed
-- and it was active today/yesterday (or `r` forces it). Keeping it gated on
-- visibility avoids spawning model calls for a hidden section.
local function should_summarize(card, force)
  if force then return true end
  if card.active then return true end
  return M._show_dormant and summarize_recent(card.last_event or card.mtime)
end

-- Load a card. Live and recent-dormant cards get the full treatment: read the
-- transcript (mtime-cached), fill the age/meta line, and request a summary.
-- Older dormant cards stay cheap -- last-active from mtime, title/first from the
-- head read done during discovery -- until `r` forces a summary.
local function load_card(card, force)
  if should_summarize(card, force) then
    if not card.transcript then return end
    card.loading = true -- spin until the summary is computed (covers reveal/reuse)
    transcript.load(card.transcript, function(bundle)
      if not bundle then return end
      if bundle.last then
        card.last_epoch = bundle.last
        card.last_ago = transcript.ago(bundle.last)
        card.meta_line = bundle.meta_line
      end
      recompute_attention(card)
      render()
      if not bundle.last then return end
      recap.request({
        session = card,
        tail = bundle.tail,
        timeline = bundle.timeline,
        mtime = bundle.mtime,
      }, function(fields, done)
        -- Merge so a re-prompt (recap's accumulator starts fresh) keeps the old
        -- prose visible until each new field lands, rather than blanking.
        card.fields = vim.tbl_extend('force', card.fields or {}, fields)
        -- Keep the spinner until ALL calls for this card finish (an idle card
        -- makes two): clearing on the first callback left a spinner gap while
        -- the second was still in flight.
        if done then
          card.loading = false
          card.refreshing = false
        end
        recompute_attention(card)
        render()
      end)
    end)
  else
    -- Cheap path: no read, no model. last_event is the true last-activity time.
    local le = card.last_event or card.mtime
    card.last_epoch = le
    card.last_ago = transcript.ago(le)
    card.meta_line = 'last active ' .. transcript.ago(le)
    card.loading = false
    card.refreshing = false -- clear any spinner flag; nothing async is coming
    recompute_attention(card)
    render()
  end
end

-- Rebuild M._cards from every conversation on disk (discovery.all), enriched
-- with live status/name for the ones that are running. Card objects are reused
-- across refreshes so loaded fields survive.
local function populate()
  local by_sid = {}
  for _, c in ipairs(M._cards) do by_sid[c.sid] = c end
  local live = {}
  for _, s in ipairs(discovery.list()) do live[s.sid] = s end
  local cards = {}
  for _, c in ipairs(discovery.all()) do
    local card = by_sid[c.sid] or { sid = c.sid, fields = {} }
    local l = live[c.sid]
    card.active = c.live
    card.cwd = c.cwd
    card.title = c.title
    card.first = c.first
    card.mtime = c.mtime
    card.last_event = c.last -- true last-activity time (not file mtime)
    card.pid = c.pid
    card.transcript = (l and l.transcript) or c.path
    card.status = l and l.status or nil
    card.name = (l and l.name) or c.title or vim.fs.basename(c.cwd or '')
    card.last_epoch = c.last
    card.last_ago = transcript.ago(c.last)
    -- Set every populate so a reused card re-spins when it will re-summarize
    -- (e.g. the active session whose transcript changed since the last open).
    card.loading = should_summarize(card)
    recompute_attention(card)
    cards[#cards + 1] = card
  end
  M._cards = cards
end

-- Open the dashboard and (re)load every card. Dormant starts hidden, so their
-- load stays cheap until revealed.
function M.open()
  M._show_dormant = config.opts.show_dormant
  populate()
  ui.open(sorted(), M._show_dormant)
  for _, card in ipairs(M._cards) do load_card(card) end
end

-- Reveal/hide the dormant section (bound to <Tab>). On reveal, (re)load the
-- dormant cards so recent ones get summarized now rather than at open.
function M.toggle_dormant()
  M._show_dormant = not M._show_dormant
  render()
  if M._show_dormant then
    for _, card in ipairs(M._cards) do
      if not card.active then load_card(card) end
    end
  end
end

-- Refresh in place: re-enumerate and reload. Summaries are mtime-cached, so
-- unchanged sessions cost nothing; only advanced transcripts re-summarize.
function M.refresh()
  populate()
  for _, card in ipairs(M._cards) do card.refreshing = true end
  render()
  for _, card in ipairs(M._cards) do load_card(card) end
end

-- Force a full re-summarization (drops the summary cache first).
function M.refresh_full()
  recap.clear()
  M.refresh()
end

-- Re-prompt a single card's summaries (bound to `r` on the selected card). The
-- deterministic fields refresh too, since load_card re-reads the transcript.
function M.refresh_card(sid)
  recap.invalidate(sid)
  for _, card in ipairs(M._cards) do
    if card.sid == sid then
      card.refreshing = true -- spinner; existing prose stays until new lands
      render()
      load_card(card, true) -- force: summarize even an older dormant card
      return
    end
  end
end

-- Delete a dormant conversation's transcript from disk and drop its card. Guards
-- against deleting a live session or any path outside claude_dir/projects.
function M.delete_card(sid)
  local idx
  for i, c in ipairs(M._cards) do if c.sid == sid then idx = i break end end
  if not idx then return end
  local card = M._cards[idx]
  if card.active then return end -- never delete a running session's transcript

  local proj = config.opts.claude_dir .. '/projects/'
  local path = card.transcript
  if not (path and path:sub(1, #proj) == proj and path:match('%.jsonl$')) then
    vim.notify('aaag: refusing to delete unexpected path: ' .. tostring(path),
      vim.log.levels.ERROR)
    return
  end
  local ok, err = os.remove(path)
  if not ok then
    vim.notify('aaag: delete failed: ' .. tostring(err), vim.log.levels.ERROR)
    return
  end
  recap.invalidate(sid)
  table.remove(M._cards, idx)
  render()
  vim.notify('aaag: deleted ' .. card.name)
end

function M.toggle()
  if ui.is_open() then ui.close() else M.open() end
end

-- Telescope picker over *all* conversations on disk (live and dormant), for
-- resuming a medium-term one you set aside. Cheap metadata only; separate from
-- the live dashboard on purpose.
function M.browse()
  require('aaag.picker').browse()
end

-- Inert <Plug> mappings for the global actions, so users can bind their own keys
-- to a stable name (mirrors cwdtabs' convention). Defined unconditionally;
-- set_default_keymaps wires the built-in bindings through them.
local function set_plug_mappings()
  local map = vim.keymap.set
  map('n', '<Plug>(aaag-toggle)', M.toggle, { desc = 'aaag: toggle dashboard' })
  map('n', '<Plug>(aaag-open)', M.open, { desc = 'aaag: open dashboard' })
  map('n', '<Plug>(aaag-refresh)', M.refresh_full,
    { desc = 'aaag: force-refresh all summaries' })
  map('n', '<Plug>(aaag-browse)', M.browse,
    { desc = 'aaag: browse all conversations' })
end

-- Only the dashboard toggle is bound by default: 'gA' shadows no built-in. Wired
-- through <Plug> so the rhs expands (remap = true).
local function set_default_keymaps()
  vim.keymap.set('n', 'gA', '<Plug>(aaag-toggle)',
    { remap = true, desc = 'aaag: toggle agents-at-a-glance dashboard' })
end

local function set_commands()
  local cmd = vim.api.nvim_create_user_command
  cmd('Aaag', M.open, { desc = 'aaag: open the sessions dashboard' })
  cmd('AaagToggle', M.toggle, { desc = 'aaag: toggle the sessions dashboard' })
  cmd('AaagRefresh', M.refresh_full, { desc = 'aaag: force-refresh summaries' })
  cmd('AaagBrowse', M.browse,
    { desc = 'aaag: browse all conversations (telescope)' })
end

function M.setup(opts)
  config.set(opts)
  ui.set_highlights()
  local group = vim.api.nvim_create_augroup('aaag', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme',
    { group = group, callback = ui.set_highlights })
  ui.on_refresh = M.refresh
  ui.on_refresh_card = M.refresh_card
  ui.on_toggle_dormant = M.toggle_dormant
  ui.on_delete_card = M.delete_card
  set_commands()
  set_plug_mappings()
  if config.opts.default_keymaps then set_default_keymaps() end
end

return M

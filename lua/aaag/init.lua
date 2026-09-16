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

local function sorted()
  local copy = vim.list_slice(M._cards, 1, #M._cards)
  table.sort(copy, function(a, b)
    local pa = PRIORITY[a.attention] or 3
    local pb = PRIORITY[b.attention] or 3
    if pa ~= pb then return pa < pb end
    return (a.last_epoch or 0) > (b.last_epoch or 0)
  end)
  return copy
end

-- Read a card's transcript (async), fill its deterministic fields, then request
-- its summary. Called for each card after discovery.
local function load_card(card)
  if not card.transcript then return end
  transcript.load(card.transcript, function(bundle)
    if not bundle then return end
    if bundle.last then
      card.last_epoch = bundle.last
      card.last_ago = transcript.ago(bundle.last)
      card.meta_line = bundle.meta_line
    end
    recompute_attention(card)
    ui.update(sorted())
    if not bundle.last then return end
    recap.request({
      session = card,
      tail = bundle.tail,
      timeline = bundle.timeline,
      mtime = bundle.mtime,
    }, function(fields)
      -- Merge so a re-prompt (which starts recap's accumulator fresh) keeps the
      -- old prose visible until each new field lands, rather than blanking.
      card.fields = vim.tbl_extend('force', card.fields or {}, fields)
      card.loading = false
      recompute_attention(card)
      ui.update(sorted())
    end)
  end)
end

-- Rebuild M._cards from the live sessions, reusing existing card objects so
-- their loaded state/fields survive a refresh.
local function populate()
  local by_sid = {}
  for _, c in ipairs(M._cards) do by_sid[c.sid] = c end
  local cards = {}
  for _, s in ipairs(discovery.list()) do
    local card = by_sid[s.sid]
      or { sid = s.sid, fields = {}, loading = true, attention = 'loading' }
    card.pid = s.pid
    card.name = s.name
    card.cwd = s.cwd
    card.status = s.status
    card.transcript = s.transcript
    recompute_attention(card)
    cards[#cards + 1] = card
  end
  M._cards = cards
end

-- Open the dashboard and (re)load every card.
function M.open()
  populate()
  ui.open(sorted())
  for _, card in ipairs(M._cards) do load_card(card) end
end

-- Refresh in place: re-enumerate and reload. Summaries are mtime-cached, so
-- unchanged sessions cost nothing; only advanced transcripts re-summarize.
function M.refresh()
  populate()
  ui.update(sorted())
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
    if card.sid == sid then load_card(card); return end
  end
end

function M.toggle()
  if ui.is_open() then ui.close() else M.open() end
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
end

function M.setup(opts)
  config.set(opts)
  ui.set_highlights()
  local group = vim.api.nvim_create_augroup('aaag', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme',
    { group = group, callback = ui.set_highlights })
  ui.on_refresh = M.refresh
  ui.on_refresh_card = M.refresh_card
  set_commands()
  set_plug_mappings()
  if config.opts.default_keymaps then set_default_keymaps() end
end

return M

-- aaag summaries: turn a session's transcript into the card's prose fields.
--
-- Two model surfaces, split by what changes fast vs slow (validated by
-- experiment):
--   A -- identity (Thread/Thesis): a fork of the live session, so it sees the
--        full/compacted context. Rich, slow-changing -> cached hard. BUT a fork
--        of a mid-turn transcript continues the conversation instead of
--        summarizing, so A is used ONLY on idle sessions; busy ones fall back.
--   B -- live state (Now/Last/State/Arc): a stateless one-shot over an assembled
--        recent-tail + timeline. Cheap, no session file created, faithful to the
--        latest turns -> recomputed whenever the transcript changes.
-- A busy session gets a single B call producing all six fields.
--
-- Results are cached by (sid, transcript mtime): an unchanged session is never
-- re-summarized. Identity additionally survives an mtime bump (it rarely
-- changes) until a full refresh clears the cache.

local config = require('aaag.config')

local M = {}

local A_IDENTITY = [[
Produce the durable IDENTITY of THIS session -- the part that stays true across
the whole conversation, for a dashboard that caches this and refreshes it rarely.
Use the full conversation context. Do NOT use any tools. Terse, no preamble, no
markdown headers, no closing remarks. One field, one to two sentences:

Thread: what this session is fundamentally about and what success looks like.
]]

local B_STATE = [[
Below is the recent transcript tail of a Claude Code session (older turns and
tool outputs elided) followed by an activity timeline. Produce the CURRENT STATE
for a dashboard. Be terse: each field on its own line, ~16 words max, no preamble,
no markdown headers, no closing remarks.

Now: the specific sub-task in focus right now.
Last from me: paraphrase of my most recent message (the last USER turn).
Agent state: what the assistant was doing in its last turn; if it finished and is
awaiting input write "waiting -- <what for>"; if the last USER turn says the
session is done/closed, write "closed by me -- safe to write off".
Arc: ONE sentence on the session's temporal shape, using ONLY the timeline below
(do NOT treat this recap query itself as activity).

--- TRANSCRIPT TAIL ---
]]

local B_FULL = [[
Below is the recent transcript tail of a Claude Code session (older turns and
tool outputs elided) followed by an activity timeline. Produce a status card so I
can recontextualize the session at a glance. Be terse: each field on its own
line, ~16 words max, no preamble, no markdown headers, no closing remarks.

Thread: one to two sentences -- what this session is fundamentally about and
what success looks like.
Now: the specific sub-task in focus right now.
Last from me: paraphrase of my most recent message (the last USER turn).
Agent state: what the assistant was doing last; if awaiting input write
"waiting -- <what for>"; if the last USER turn closes it write "closed by me --
safe to write off".
Arc: ONE sentence on the session's temporal shape, using ONLY the timeline below.

--- TRANSCRIPT TAIL ---
]]

-- sid -> { mtime, fields } ; fields = { thread, thesis, now, last, state, arc }
local cache = {}

-- Map a model output line "Label: value" (tolerating **bold** and case) onto a
-- card field key. Unknown labels are ignored.
local LABELS = {
  thread = 'thread', now = 'now',
  ['last from me'] = 'last', ['last'] = 'last',
  ['agent state'] = 'state', ['state'] = 'state', arc = 'arc',
}

local function parse_fields(text)
  local fields = {}
  for line in text:gmatch('[^\n]+') do
    local label, val = line:match('^%s*%**%s*([%a%s]-)%s*%**%s*:%s*(.*)$')
    if label then
      local key = LABELS[vim.trim(label:lower())]
      if key then
        fields[key] = vim.trim((val:gsub('%*+%s*$', '')))
      end
    end
  end
  return fields
end

-- `claude` must be on PATH to produce summaries. Check once and warn once; the
-- deterministic card fields (age, cwd, status) render regardless.
local warned = false
local function have_claude()
  if vim.fn.executable('claude') == 1 then return true end
  if not warned then
    warned = true
    vim.notify('aaag: `claude` not found on PATH -- summaries unavailable',
      vim.log.levels.WARN)
  end
  return false
end

-- Spawn one `claude` summary call. `resume_sid` non-nil selects method A (fork
-- of that session); nil selects method B (stateless). on_done(fields|nil).
local function run(prompt, cwd, resume_sid, on_done)
  local argv = { 'claude', '-p', prompt,
    '--model', config.opts.model, '--tools', 'none', '--strict-mcp-config' }
  if resume_sid then
    vim.list_extend(argv, { '--resume', resume_sid, '--fork-session' })
  end
  vim.system(argv, { cwd = cwd, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not res.stdout or res.stdout == '' then
        return on_done(nil)
      end
      on_done(parse_fields(res.stdout))
    end)
  end)
end

-- Public: compute a session's card fields, calling on_update(fields) possibly
-- more than once as A and B land (so the UI can fill in progressively). opts:
--   { session = <discovery entry>, tail = <string>, timeline = <string>,
--     mtime = <number> }
function M.request(opts, on_update)
  if not have_claude() then return end
  local sid = opts.session.sid
  local cached = cache[sid]
  if cached and cached.mtime == opts.mtime then
    return on_update(vim.deepcopy(cached.fields))
  end

  local fields = (cached and cached.fields) or {}
  cache[sid] = { mtime = opts.mtime, fields = fields }
  local body = opts.tail .. '\n\n--- ACTIVITY TIMELINE (my records) ---\n'
    .. opts.timeline

  local function merge(new)
    if new then fields = vim.tbl_extend('force', fields, new) end
    cache[sid] = { mtime = opts.mtime, fields = fields }
    on_update(vim.deepcopy(fields))
  end

  if opts.session.status == 'idle' then
    -- A for identity (only reuse a prior identity if we have one this mtime).
    if not fields.thread then
      run(A_IDENTITY, opts.session.cwd, sid, merge)
    end
    run(B_STATE .. body, opts.session.cwd, nil, merge)
  else
    -- Busy / mid-turn: one stateless call for everything (fork would ramble).
    run(B_FULL .. body, opts.session.cwd, nil, merge)
  end
end

-- Drop all cached summaries so the next request recomputes from scratch.
function M.clear()
  cache = {}
end

return M

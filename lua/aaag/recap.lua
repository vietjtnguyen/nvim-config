-- aaag summaries: turn a session's transcript into the card's prose fields.
--
-- Two model surfaces, split by how fast the content changes:
--   A -- identity (Thread): a fork of the live session, so it sees the full
--        (compacted) context. Slow-changing, cached hard. A fork of a mid-turn
--        session continues the conversation instead of summarizing, so A runs
--        only on idle sessions.
--   B -- live state (Now/Last/State/Arc): a stateless one-shot over the recent
--        tail + timeline. Cheap, faithful to the latest turns, recomputed when
--        the transcript changes.
-- A busy session gets a single B call producing all six fields.
--
-- Cached by (sid, transcript mtime); identity survives an mtime bump until a
-- full refresh, since it rarely changes.

local config = require('aaag.config')

local M = {}

local A_IDENTITY = [[
Produce the durable IDENTITY of THIS session -- the part that stays true across
the whole conversation, for a dashboard that caches this and refreshes it rarely.
Use the full conversation context. Do NOT use any tools. Terse plain prose --
no Markdown formatting (no **bold**, backticks, headings, or bullets), no
preamble, no closing remarks. One field, one to two sentences:

Thread: what this session is fundamentally about and what success looks like.
]]

local B_STATE = [[
Below is the recent transcript tail of a Claude Code session (older turns and
tool outputs elided) followed by an activity timeline. Produce the CURRENT STATE
for a dashboard. Be terse: each field on its own line, ~16 words max, plain prose
-- no Markdown formatting (no **bold**, backticks, headings, or bullets), no
preamble, no closing remarks.

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
line, ~16 words max, plain prose -- no Markdown formatting (no **bold**,
backticks, headings, or bullets), no preamble, no closing remarks.

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

-- sid -> {
--   mtime, token, fields = { thread, now, last, state, arc },
--   pending,      -- jobs not yet reported (0 => done)
--   done,         -- true once every job has reported
--   failed, total,-- how many of `total` jobs failed, for the retry note
--   callbacks,    -- on_update fns to notify as fields land (dup loads coalesce)
-- }
-- The entry is written before its jobs run, so state is explicit: a same-mtime
-- request while pending attaches as another callback (no duplicate subprocess,
-- no false "done"); a finished entry is served as-is and never auto-retried, so
-- a failure carries a note to press `r`. token drops a late callback from a
-- superseded request (advanced transcript or forced refresh) so it can't
-- overwrite fresher fields.
local cache = {}
local generation = 0

-- The "some jobs failed" note shown on a card until `r` re-prompts it. nil when
-- every job succeeded.
local function fail_note(entry)
  if entry.failed == 0 then return nil end
  return string.format('summary failed (%d/%d) -- press r to retry',
    entry.failed, entry.total)
end

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
        -- Strip any stray Markdown the model still emits (bold, backticks).
        local v = val:gsub('%*%*', ''):gsub('`', '')
        fields[key] = vim.trim(v)
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
  -- --tools "" disables all tools (the documented form; summaries never act).
  -- --no-session-persistence keeps the call ephemeral: it reads the parent
  -- context for a fork but writes no transcript of its own, so summaries never
  -- litter ~/.claude.
  local argv = { 'claude', '-p', prompt, '--model', config.opts.model,
    '--tools', '', '--strict-mcp-config', '--no-session-persistence' }
  if resume_sid then
    vim.list_extend(argv, { '--resume', resume_sid, '--fork-session' })
  end
  -- The conversation's work dir may be gone (deleted/moved); spawning with a
  -- non-existent cwd raises a loud ENOENT, so fall back to inheriting Neovim's.
  local runcwd = (cwd and vim.fn.isdirectory(cwd) == 1) and cwd or nil
  vim.system(argv, { cwd = runcwd, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not res.stdout or res.stdout == '' then
        return on_done(nil)
      end
      on_done(parse_fields(res.stdout))
    end)
  end)
end

-- Public: compute a session's card fields, calling on_update(fields, done, note)
-- possibly more than once as A and B land (so the UI can fill in progressively).
-- `done` is true once every job has reported; `note` is nil unless some job
-- failed. On failure or a missing CLI, on_update still fires with done=true so
-- the caller can settle its spinner (fields may be nil). opts:
--   { session = <discovery entry>, tail = <string>, timeline = <string>,
--     mtime = <number> }
function M.request(opts, on_update)
  if not have_claude() then
    return on_update(nil, true, 'claude not on PATH -- summaries unavailable')
  end
  local sid = opts.session.sid
  local cached = cache[sid]
  if cached and cached.mtime == opts.mtime then
    -- Same transcript. A finished entry is served as-is (a failure is not
    -- retried automatically); an in-flight one gets this caller added as another
    -- waiter, so a duplicate load coalesces onto the running jobs.
    if cached.done then
      return on_update(vim.deepcopy(cached.fields), true, fail_note(cached))
    end
    cached.callbacks[#cached.callbacks + 1] = on_update
    return on_update(vim.deepcopy(cached.fields), false)
  end

  generation = generation + 1
  local token = generation
  local entry = {
    mtime = opts.mtime, token = token,
    fields = (cached and cached.fields) or {},
    failed = 0, done = false, callbacks = { on_update },
  }
  cache[sid] = entry
  local body = opts.tail .. '\n\n--- ACTIVITY TIMELINE (my records) ---\n'
    .. opts.timeline

  -- The model calls to make. Idle sessions get A (identity, forked) unless a
  -- prior identity survives this mtime, plus B (live state); busy sessions get a
  -- single stateless B_FULL (a fork of a mid-turn session would ramble).
  local jobs = {}
  if opts.session.status == 'idle' then
    if not entry.fields.thread then
      jobs[#jobs + 1] = { A_IDENTITY, opts.session.cwd, sid }
    end
    jobs[#jobs + 1] = { B_STATE .. body, opts.session.cwd, nil }
  else
    jobs[#jobs + 1] = { B_FULL .. body, opts.session.cwd, nil }
  end
  entry.total = #jobs
  entry.pending = #jobs

  -- A job reports merge(fields) on success or merge(nil) on failure. A late
  -- callback from a superseded request is dropped. Once every job has reported,
  -- the entry is done: its fields (whatever landed) are kept and never
  -- auto-recomputed at this mtime; a non-zero `failed` count surfaces as a note.
  local function merge(new)
    local cur = cache[sid]
    if not cur or cur.token ~= token then return end
    if new then
      cur.fields = vim.tbl_extend('force', cur.fields, new)
    else
      cur.failed = cur.failed + 1
    end
    cur.pending = cur.pending - 1
    local done = cur.pending == 0
    if done then cur.done = true end
    local snapshot = vim.deepcopy(cur.fields)
    local note = done and fail_note(cur) or nil
    for _, cb in ipairs(cur.callbacks) do cb(snapshot, done, note) end
  end

  for _, j in ipairs(jobs) do run(j[1], j[2], j[3], merge) end
end

-- Drop all cached summaries so the next request recomputes from scratch.
function M.clear()
  cache = {}
end

-- Drop one session's cached summary, so the next request re-prompts it.
function M.invalidate(sid)
  cache[sid] = nil
end

return M

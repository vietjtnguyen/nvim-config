-- aaag discovery: enumerate the *live* Claude Code sessions, entirely by
-- observation -- no launcher, no registry of our own.
--
-- The authoritative source is Claude Code's own per-process metadata at
-- <claude_dir>/sessions/{PID}.json, which each live CLI writes and keeps current
-- (v2.1.x). One file per process gives us pid, sessionId, cwd, a derived name,
-- and a live idle/busy status. We keep only the files whose PID is still a
-- running `claude`, so a stale metadata file from a crashed session drops out.

local config = require('aaag.config')

local M = {}

-- Is `pid` a live claude process? We read /proc/<pid>/comm: it both proves
-- liveness and confirms identity, so a recycled PID belonging to some other
-- program is rejected. aaag is Linux-only (see :checkhealth aaag) -- a signal-0
-- probe was tempting off Linux, but libuv returns ESRCH as a value rather than
-- throwing, so pcall reports a dead PID as live; without /proc we simply cannot
-- verify, so we report not-live rather than trusting a stale metadata file.
local function comm_of(pid)
  local f = io.open('/proc/' .. pid .. '/comm', 'r')
  if not f then return nil end
  local c = f:read('*l')
  f:close()
  return c
end

local function is_live_claude(pid)
  local c = comm_of(pid)
  -- comm is truncated to 15 bytes by the kernel; "claude" fits, but match
  -- loosely in case the exec name ever changes.
  return c ~= nil and (c == 'claude' or c:match('claude'))
end

-- Read and decode one small JSON file, or nil on any error.
local function read_json(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  local ok, decoded = pcall(vim.json.decode, text)
  return ok and decoded or nil
end

-- Locate the transcript .jsonl for a session. Claude Code encodes the cwd into
-- the project directory name by replacing every non-alphanumeric run's chars
-- with '-', so we reconstruct that first (one stat, no globbing). If the encoded
-- guess misses -- unusual cwd characters, a moved session -- we fall back to a
-- recursive glob for "<sid>.jsonl", which is correct but slower.
local function transcript_path(cwd, sid)
  local projects = config.opts.claude_dir .. '/projects'
  local encoded = cwd:gsub('[^%w]', '-')
  local guess = projects .. '/' .. encoded .. '/' .. sid .. '.jsonl'
  if vim.uv.fs_stat(guess) then return guess end
  local hits = vim.fn.glob(projects .. '/**/' .. sid .. '.jsonl', false, true)
  return hits[1]
end

-- Map of live interactive sessions, sid -> pid, for cross-referencing the full
-- conversation list against what's currently running.
function M.live_map()
  local dir = config.opts.claude_dir .. '/sessions'
  local map = {}
  for _, path in ipairs(vim.fn.glob(dir .. '/*.json', false, true)) do
    local pid = tonumber(vim.fn.fnamemodify(path, ':t:r'))
    if pid and is_live_claude(pid) then
      local meta = read_json(path)
      if meta and meta.sessionId
          and (meta.kind == nil or meta.kind == 'interactive') then
        map[meta.sessionId] = pid
      end
    end
  end
  return map
end

-- Cheap metadata without a full read: cwd, the generated title ("aiTitle"), the
-- first user message (from a bounded head), and `last` -- the epoch of the final
-- timestamped event (from a bounded tail). We sort/age dormant cards by `last`,
-- not the file mtime, which resume/metadata writes bump without adding events.
-- The head is large enough to clear a leading oversized record; individual
-- records above a size cap are skipped when decoding the first message.
local function head_meta(path, size)
  local f = io.open(path, 'r')
  if not f then return {} end
  local head = f:read(131072) or ''
  local tail = head
  if size and size > #head then
    f:seek('set', math.max(0, size - 65536))
    tail = f:read('*a') or ''
  end
  f:close()

  local meta = {
    cwd = head:match('"cwd":"([^"]*)"'),
    title = head:match('"aiTitle":"([^"]*)"'),
  }
  for line in head:gmatch('[^\n]+') do
    if #line <= 32768 then
      local ok, d = pcall(vim.json.decode, line)
      if ok and type(d) == 'table' and d.type == 'user'
          and type(d.message) == 'table' then
        local c, text = d.message.content, nil
        if type(c) == 'string' then
          text = c
        elseif type(c) == 'table' then
          for _, b in ipairs(c) do
            if type(b) == 'table' and b.type == 'text' then text = b.text break end
          end
        end
        if text and text ~= '' then
          meta.first = (text:gsub('%s+', ' ')):sub(1, 200)
          break
        end
      end
    end
  end

  local last_iso
  for iso in tail:gmatch('"timestamp":"([^"]+)"') do last_iso = iso end
  meta.last = require('aaag.transcript').iso_epoch(last_iso)
  return meta
end

-- Public: every conversation transcript on disk, newest-first, with only cheap
-- metadata -- no model calls, no full reads. Subagent transcripts (under a
-- ".../subagents/" directory) are excluded; they aren't conversations you'd
-- resume. Each entry: { sid, path, cwd, title, first, mtime, live, pid }
function M.all()
  local live = M.live_map()
  local out = {}
  local proj = config.opts.claude_dir .. '/projects'
  for _, path in ipairs(vim.fn.glob(proj .. '/**/*.jsonl', false, true)) do
    local st = vim.uv.fs_stat(path)
    if st and not path:find('/subagents/', 1, true) then
      local sid = vim.fn.fnamemodify(path, ':t:r')
      local meta = head_meta(path, st.size)
      out[#out + 1] = {
        sid = sid,
        path = path,
        cwd = meta.cwd,
        title = meta.title,
        first = meta.first,
        last = meta.last or st.mtime.sec, -- true last-event time; mtime fallback
        mtime = st.mtime.sec,
        live = live[sid] ~= nil,
        pid = live[sid],
      }
    end
  end
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  return out
end

-- Public: the live sessions right now, as plain data, in no guaranteed order
-- (the caller sorts for display). Each entry:
--   { pid, sid, cwd, name, status, transcript }
-- status is Claude's own 'idle'/'busy'; transcript may be nil if not found.
function M.list()
  local dir = config.opts.claude_dir .. '/sessions'
  local sessions = {}
  for _, path in ipairs(vim.fn.glob(dir .. '/*.json', false, true)) do
    local pid = tonumber(vim.fn.fnamemodify(path, ':t:r'))
    if pid and is_live_claude(pid) then
      local meta = read_json(path)
      -- Only interactive sessions belong on the dashboard. A short-lived
      -- `claude -p` fork (e.g. the one aaag itself spawns for a summary) writes
      -- its own metadata with a non-interactive kind; skip those so a refresh
      -- landing in that window can't flash a phantom card.
      if meta and meta.sessionId and meta.cwd
          and (meta.kind == nil or meta.kind == 'interactive') then
        sessions[#sessions + 1] = {
          pid = pid,
          sid = meta.sessionId,
          cwd = meta.cwd,
          name = meta.name or meta.sessionId:sub(1, 8),
          status = meta.status or 'idle',
          transcript = transcript_path(meta.cwd, meta.sessionId),
        }
      end
    end
  end
  return sessions
end

return M

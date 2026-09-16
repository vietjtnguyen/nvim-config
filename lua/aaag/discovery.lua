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

-- Is `pid` a live claude process? On Linux we read /proc/<pid>/comm: it both
-- proves liveness and confirms identity, so a recycled PID belonging to some
-- other program is rejected. Off Linux (no /proc) we fall back to signal-0,
-- which proves liveness but not identity -- acceptable, recycled PIDs are rare.
local function comm_of(pid)
  local f = io.open('/proc/' .. pid .. '/comm', 'r')
  if not f then return nil end
  local c = f:read('*l')
  f:close()
  return c
end

local function is_live_claude(pid)
  if vim.uv.fs_stat('/proc') then
    local c = comm_of(pid)
    -- comm is truncated to 15 bytes by the kernel; "claude" fits, but match
    -- loosely in case the exec name ever changes.
    return c ~= nil and (c == 'claude' or c:match('claude'))
  end
  local ok = pcall(vim.uv.kill, pid, 0)
  return ok
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

-- Cheap metadata from a bounded head read (no full read): the recorded cwd, the
-- generated title (the "aiTitle" record, grabbed by pattern -- concise and
-- search-friendly), and the first user message. The head is large enough to
-- clear a leading oversized record (e.g. a big "queue-operation"); individual
-- records above a size cap are skipped when decoding for the first message so a
-- huge pasted record doesn't cost a full parse. Returns { cwd, title, first }.
local function head_meta(path)
  local f = io.open(path, 'r')
  if not f then return {} end
  local head = f:read(131072) or ''
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
      local meta = head_meta(path)
      out[#out + 1] = {
        sid = sid,
        path = path,
        cwd = meta.cwd,
        title = meta.title,
        first = meta.first,
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

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

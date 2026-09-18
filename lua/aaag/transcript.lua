-- aaag transcript parsing: the deterministic layer. Everything here comes
-- straight from the on-disk JSONL with no model call -- age, the activity
-- timeline, and the recent-turns tail we later hand to the summarizer.
--
-- The file read is async (libuv), so opening the dashboard doesn't wait on
-- disk. The parsing that follows runs on the main loop, so a very large
-- transcript (tens of MB) can still cost a beat -- the per-file bounds here and
-- the mtime cache in M.load keep that off the common path.

local config = require('aaag.config')

local M = {}

-- Days from the Unix epoch (1970-01-01) for a Gregorian Y/M/D, by Howard
-- Hinnant's days_from_civil algorithm. Transcript timestamps are UTC ("...Z"),
-- so we build the epoch arithmetically rather than via os.time(), which reads a
-- broken-down table in the *local* zone -- wrong for a UTC wall clock, and wrong
-- by a DST-dependent amount that a single "current" offset can't correct for a
-- timestamp from another season.
local function days_from_civil(y, m, d)
  y = (m <= 2) and (y - 1) or y
  local era = math.floor((y >= 0 and y or y - 399) / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * ((m > 2) and (m - 3) or (m + 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function iso_to_epoch(iso)
  local y, mo, d, h, mi, s =
    iso:match('(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  if not y then return nil end
  return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

-- Human "3d ago" / "20m ago" from an epoch, relative to now.
local function ago(epoch)
  local s = os.time() - epoch
  if s < 90 then return string.format('%ds ago', s) end
  if s < 5400 then return string.format('%dm ago', math.floor(s / 60)) end
  if s < 129600 then return string.format('%dh ago', math.floor(s / 3600)) end
  return string.format('%dd ago', math.floor(s / 86400))
end

-- Public form of the relative-time helper, for a card's short header age.
M.ago = ago

-- Public: convert one ISO-8601 UTC timestamp string to an epoch (or nil).
function M.iso_epoch(iso)
  return iso and iso_to_epoch(iso)
end

-- Read a transcript file asynchronously. Calls cb(stat, content) on success or
-- cb(nil) on any failure; stat carries mtime/size so callers can cache on it.
function M.read(path, cb)
  vim.uv.fs_open(path, 'r', 438, function(oerr, fd)
    if oerr or not fd then return vim.schedule(function() cb(nil) end) end
    vim.uv.fs_fstat(fd, function(serr, stat)
      if serr or not stat then
        vim.uv.fs_close(fd)
        return vim.schedule(function() cb(nil) end)
      end
      vim.uv.fs_read(fd, stat.size, 0, function(rerr, data)
        vim.uv.fs_close(fd)
        vim.schedule(function()
          if rerr or not data then return cb(nil) end
          cb(stat, data)
        end)
      end)
    end)
  end)
end

-- Deterministic activity stats from raw transcript content. Timestamps are
-- scanned with a plain pattern (no per-line JSON decode) so this stays cheap
-- even on the largest files. Returns nil if the transcript carries no
-- timestamps. Fields: first, last (epoch), count, span_days, by_day (ordered
-- {date,count}), gap ({hours, ends_iso} or nil for the longest quiet stretch).
function M.stats(content)
  local epochs = {}
  for iso in content:gmatch('"timestamp":"([^"]+)"') do
    local e = iso_to_epoch(iso)
    if e then epochs[#epochs + 1] = e end
  end
  if #epochs == 0 then return nil end

  table.sort(epochs)
  -- Bucket by *local* calendar day (os.date without '!'), matching the local
  -- clock the AGE line prints -- otherwise a card mixes UTC and local dates.
  local by_count = {}
  for _, e in ipairs(epochs) do
    local dt = os.date('%Y-%m-%d', e)
    by_count[dt] = (by_count[dt] or 0) + 1
  end
  local day_keys = vim.tbl_keys(by_count)
  table.sort(day_keys)
  local by_day = {}
  for _, dt in ipairs(day_keys) do
    by_day[#by_day + 1] = { date = dt, count = by_count[dt] }
  end

  -- Longest gap between consecutive events -- how we spot "quiet for a week,
  -- then picked back up". Only surfaced when it is genuinely long.
  local gap
  for i = 2, #epochs do
    local d = epochs[i] - epochs[i - 1]
    if not gap or d > gap.secs then
      gap = { secs = d, ends = epochs[i] }
    end
  end
  if gap and gap.secs < 6 * 3600 then gap = nil end

  local first, last = epochs[1], epochs[#epochs]
  return {
    first = first,
    last = last,
    count = #epochs,
    span_days = math.floor((last - first) / 86400),
    active_days = #by_day,
    by_day = by_day,
    gap = gap,
  }
end

-- One deterministic, label-less meta line for the card. Combines age and (when
-- present) the quiet-gap into a single "·"-separated row. The last-activity time
-- is omitted here because the card header already shows it ("last 20m ago").
function M.meta_line(st)
  local s = string.format('started %s (%s) · %d events over %d active day%s',
    os.date('%Y-%m-%d %H:%M', st.first), ago(st.first),
    st.count, st.active_days, st.active_days == 1 and '' or 's')
  if st.gap then
    s = s .. string.format(' · %dh quiet ending %s',
      math.floor(st.gap.secs / 3600), os.date('%m-%d %H:%M', st.gap.ends))
  end
  return s
end

-- Compact per-day timeline handed to the summarizer for the Arc line. Kept
-- machine-plain so the model treats it as authoritative for dates/counts.
function M.timeline_str(st)
  local parts = {}
  for _, d in ipairs(st.by_day) do
    parts[#parts + 1] = d.date .. ':' .. d.count
  end
  local s = 'Activity by day (date:event_count): ' .. table.concat(parts, '  ')
  if st.gap then
    s = s .. string.format('\nLongest quiet gap: %dh ending %s',
      math.floor(st.gap.secs / 3600), os.date('%Y-%m-%d %H:%M', st.gap.ends))
  end
  return s
end

-- Extract the text of a message record's content, which is either a plain string
-- or a list of blocks. We keep text blocks and a compact marker for tool_use
-- (name + first meaningful target); tool_result bodies and thinking are dropped
-- -- they are bulky and rarely help a recap.
local function message_text(msg)
  local content = msg.content
  if type(content) == 'string' then return content end
  if type(content) ~= 'table' then return '' end
  local parts = {}
  for _, b in ipairs(content) do
    if type(b) == 'table' then
      if b.type == 'text' and b.text then
        parts[#parts + 1] = b.text
      elseif b.type == 'tool_use' then
        local inp = b.input or {}
        local tgt = inp.file_path or inp.command or inp.path or inp.pattern or ''
        parts[#parts + 1] =
          string.format('[tool:%s %s]', b.name or '?', tostring(tgt):sub(1, 80))
      end
    end
  end
  return table.concat(parts, '\n')
end

-- Assemble the recent-turns tail for the stateless (B) summary. We decode only
-- the last slice of lines (not the whole file), collect user/assistant turns
-- newest-first until either cap (tail_msgs turns or tail_chars characters) is
-- hit, then restore chronological order. All sizes are counted in characters,
-- not bytes, so a cap can't fall mid-UTF-8-sequence.
local SEP = '\n\n'
function M.assemble_tail(content)
  local max_msgs = config.opts.tail_msgs
  local char_cap = config.opts.tail_chars
  local block_cap = 1200

  -- Only the tail matters, so split just the last slice of the file rather than
  -- the whole (multi-MB) transcript. 1 MiB comfortably holds the recent
  -- max_msgs*8 records; if we cut mid-record the leading partial line fails to
  -- decode and is skipped, costing at most one older turn.
  local TAIL_BYTES = 1024 * 1024
  local tail = #content > TAIL_BYTES and content:sub(-TAIL_BYTES) or content
  local lines = vim.split(tail, '\n', { plain = true, trimempty = true })
  if #content > TAIL_BYTES then table.remove(lines, 1) end
  -- Decode at most this many trailing lines; max_msgs turns live well within it
  -- even with interleaved meta/tool records.
  local from = math.max(1, #lines - max_msgs * 8)

  local turns = {}
  for i = from, #lines do
    local ok, d = pcall(vim.json.decode, lines[i])
    if ok and type(d) == 'table' and (d.type == 'user' or d.type == 'assistant')
        and type(d.message) == 'table' then
      local text = vim.trim(message_text(d.message))
      if text ~= '' then
        if vim.fn.strchars(text) > block_cap then
          text = vim.fn.strcharpart(text, 0, block_cap) .. ' …[truncated]'
        end
        turns[#turns + 1] = { role = d.message.role or d.type, text = text }
      end
    end
  end

  local chosen, total = {}, 0
  local sep_chars = vim.fn.strchars(SEP)
  for i = #turns, 1, -1 do
    if #chosen >= max_msgs then break end
    local line = turns[i].role:upper() .. ': ' .. turns[i].text
    -- Count the joining separator (all but the first entry gets one) so the
    -- assembled string actually honours char_cap.
    local add = vim.fn.strchars(line) + (#chosen > 0 and sep_chars or 0)
    if total + add > char_cap then break end
    chosen[#chosen + 1] = line
    total = total + add
  end
  -- chosen is newest-first; reverse to chronological.
  local ordered = {}
  for i = #chosen, 1, -1 do ordered[#ordered + 1] = chosen[i] end
  return table.concat(ordered, SEP)
end

-- Everything a card needs from a transcript, cached by (path, mtime): the read,
-- the timestamp scan, the timeline, and the recent tail. An unchanged session is
-- served from cache after a single cheap fs_stat, so it is never re-read or
-- re-scanned. cb(bundle) or cb(nil) on failure; bundle has
-- { mtime, last, stats, timeline, tail } (the last four nil if the transcript
-- carries no timestamps). The meta line is NOT cached -- it embeds a relative
-- age ("3d ago") that would freeze; callers format it from `stats` per render.
local bundle_cache = {}

function M.load(path, cb)
  vim.uv.fs_stat(path, function(serr, st)
    if serr or not st then return vim.schedule(function() cb(nil) end) end
    local mtime = st.mtime.sec
    local hit = bundle_cache[path]
    if hit and hit.mtime == mtime then
      return vim.schedule(function() cb(hit) end)
    end
    M.read(path, function(rstat, content) -- M.read schedules this on the main loop
      if not rstat then return cb(nil) end
      local stats = M.stats(content)
      local bundle = { mtime = rstat.mtime.sec }
      if stats then
        bundle.last = stats.last
        bundle.stats = stats
        bundle.timeline = M.timeline_str(stats)
        bundle.tail = M.assemble_tail(content)
      end
      bundle_cache[path] = bundle
      cb(bundle)
    end)
  end)
end

return M

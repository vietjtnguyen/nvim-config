-- aaag conversation picker: a telescope list of *all* Claude Code conversations
-- on disk (live and dormant), for finding a medium-term one you set aside and
-- picking it back up. Cheap deterministic metadata only -- no model prompting.
--
-- Selecting a conversation:
--   <CR>   live  -> jump to the terminal tab already running it;
--          else  -> resume it in a new terminal tab, tcd'd to its work dir.
--   <C-t> / <C-v> / <C-x>  resume in a new tab / vsplit / split (telescope's
--          usual open-split keys), regardless of live state.

local discovery = require('aaag.discovery')
local transcript = require('aaag.transcript')
local jump = require('aaag.jump')

local M = {}

local function homed(path)
  if not path then return '(unknown cwd)' end
  return (path:gsub('^' .. vim.pesc(vim.env.HOME or '\0'), '~'))
end

-- Cheap preview: read a bounded head and tail (not the whole transcript) to
-- surface the branch and the first/last user messages.
local function user_text(msg)
  if type(msg) ~= 'table' then return nil end
  local c = msg.content
  if type(c) == 'string' then return c end
  if type(c) == 'table' then
    for _, b in ipairs(c) do
      if type(b) == 'table' and b.type == 'text' then return b.text end
    end
  end
end

local function peek(path)
  local f = io.open(path, 'r')
  if not f then return {} end
  local head = f:read(65536) or ''
  local size = f:seek('end') or 0
  f:seek('set', math.max(0, size - 65536))
  local tail = f:read('*a') or ''
  f:close()

  local info = { branch = head:match('"gitBranch":"([^"]*)"') }
  for line in head:gmatch('[^\n]+') do
    local ok, d = pcall(vim.json.decode, line)
    if ok and type(d) == 'table' and d.type == 'user' then
      local t = user_text(d.message)
      if t and t ~= '' then info.first_user = t; break end
    end
  end
  for line in tail:gmatch('[^\n]+') do
    local ok, d = pcall(vim.json.decode, line)
    if ok and type(d) == 'table' and d.type == 'user' then
      local t = user_text(d.message)
      if t and t ~= '' then info.last_user = t end
    end
  end
  return info
end

function M.browse()
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    vim.notify('aaag: telescope.nvim is required for :AaagBrowse', vim.log.levels.WARN)
    return
  end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local previewers = require('telescope.previewers')
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = 'Claude conversations',
    finder = finders.new_table({
      results = discovery.all(),
      entry_maker = function(c)
        local cwd = homed(c.cwd)
        local label = c.title or c.first
        local line = string.format('%-10s %s %-28s%s',
          transcript.ago(c.mtime), c.live and '●' or ' ', cwd,
          label and ('  ' .. label) or '')
        return {
          value = c,
          display = line,
          -- Search over the cwd, the generated title, and the first message.
          ordinal = table.concat(
            { c.cwd or '', c.title or '', c.first or '', c.sid }, ' '),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = 'Conversation',
      define_preview = function(self, entry)
        local c = entry.value
        local info = peek(c.path)
        local lines = {
          'cwd:    ' .. homed(c.cwd),
          'branch: ' .. (info.branch or '?'),
          'sid:    ' .. c.sid,
          'last:   ' .. os.date('%Y-%m-%d %H:%M', c.mtime)
            .. (c.live and '   [LIVE]' or ''),
          '',
          'First from me:',
          '  ' .. (info.first_user or '(none)'),
          '',
          'Last from me:',
          '  ' .. (info.last_user or '(none)'),
        }
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false,
          vim.split(table.concat(lines, '\n'), '\n'))
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      local function act(mode)
        return function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not entry then return end
          local c = entry.value
          -- Default on a live conversation jumps to its running tab; every other
          -- path resumes it in a fresh terminal.
          if mode == 'default' and c.live and jump.to_pid(c.pid) then return end
          jump.resume(mode == 'default' and 'tab' or mode, c.cwd, c.sid)
        end
      end
      actions.select_default:replace(act('default'))
      map({ 'i', 'n' }, '<C-t>', act('tab'))
      map({ 'i', 'n' }, '<C-v>', act('vsplit'))
      map({ 'i', 'n' }, '<C-x>', act('split'))
      return true
    end,
  }):find()
end

return M

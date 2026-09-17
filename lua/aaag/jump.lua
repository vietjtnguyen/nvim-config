-- aaag jump: from a session's live claude PID to the Neovim terminal tab that
-- hosts it, so selecting a card can switch you straight to that pane.
--
-- A terminal buffer exposes its job's PID (the shell), and the claude process is
-- a descendant of that shell. So we walk *up* from the claude PID through its
-- parents; the first ancestor that equals some terminal buffer's job PID
-- identifies the hosting tab. Walking up is a short chain (cheaper than
-- descending every terminal's subtree) and disambiguates two claude sessions
-- sharing a CWD, since it keys on the actual process, not the directory.

local M = {}

-- pid -> ppid for every process, read once per jump. /proc on Linux; `ps`
-- elsewhere. Returns {} if neither is available (jump then simply fails soft).
local function parent_map()
  local map = {}
  if vim.uv.fs_stat('/proc') then
    for _, name in ipairs(vim.fn.readdir('/proc') or {}) do
      local pid = tonumber(name)
      if pid then
        -- /proc/<pid>/stat: "pid (comm) state ppid ...". comm may contain
        -- spaces/parens, so anchor on the last ')' before the state field.
        local f = io.open('/proc/' .. pid .. '/stat', 'r')
        if f then
          local line = f:read('*a')
          f:close()
          local after = line and line:match('%)%s*(.*)$')
          if after then
            local _state, ppid = after:match('^(%S+)%s+(%d+)')
            if ppid then map[pid] = tonumber(ppid) end
          end
        end
      end
    end
  else
    local out = vim.fn.systemlist({ 'ps', '-eo', 'pid=,ppid=' })
    for _, line in ipairs(out) do
      local pid, ppid = line:match('^%s*(%d+)%s+(%d+)')
      if pid then map[tonumber(pid)] = tonumber(ppid) end
    end
  end
  return map
end

-- job PID -> { tabpage, win } for every terminal buffer currently shown in a
-- window. A terminal not visible in any window can't be jumped to, so we only
-- consider displayed ones.
local function terminal_windows()
  local by_job = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == 'terminal' then
      local job = vim.b[buf].terminal_job_pid
      if job then
        by_job[job] = {
          tabpage = vim.api.nvim_win_get_tabpage(win),
          win = win,
        }
      end
    end
  end
  return by_job
end

-- Public: switch to the terminal tab/window hosting `claude_pid`. Returns true
-- on success; false if the process isn't hosted by any visible nvim terminal
-- (e.g. it's running in tmux or an external emulator).
function M.to_pid(claude_pid)
  local parents = parent_map()
  local terms = terminal_windows()

  local pid, hops = claude_pid, 0
  while pid and hops < 64 do
    local hit = terms[pid]
    if hit then
      vim.api.nvim_set_current_tabpage(hit.tabpage)
      vim.api.nvim_set_current_win(hit.win)
      return true
    end
    pid = parents[pid]
    hops = hops + 1
  end
  return false
end

-- Open a terminal running `claude --resume <sid>` in a conversation's work dir.
-- mode 'tab' also :tcd's the new tab so cwdtabs groups it; 'vsplit'/'split' open
-- in the current tab (windows can't carry their own cwdtabs group). The command
-- is typed into a real shell, so you land back at a prompt when claude exits.
function M.resume(mode, dir, sid)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    vim.notify('aaag: work dir not found (' .. tostring(dir) .. '); opening in $HOME',
      vim.log.levels.WARN)
    dir = vim.uv.os_homedir()
  end
  if mode == 'vsplit' then
    vim.cmd('vsplit | enew')
  elseif mode == 'split' then
    vim.cmd('split | enew')
  else
    vim.cmd('tabnew')
    pcall(function() vim.cmd.tcd(dir) end)
  end
  local chan = vim.fn.jobstart(vim.o.shell, { term = true, cwd = dir })
  if chan > 0 then
    -- Small delay so the shell's rc is loaded before we type the command.
    vim.defer_fn(function()
      pcall(vim.api.nvim_chan_send, chan, 'claude --resume ' .. sid .. '\r')
    end, 150)
  end
  vim.cmd('startinsert')
end

return M

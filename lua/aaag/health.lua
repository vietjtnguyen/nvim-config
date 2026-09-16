-- aaag health check: `:checkhealth aaag`. Everything aaag depends on is
-- environmental (an external CLI, Linux /proc, an optional plugin), so this is
-- the idiomatic place to tell the user what's missing and why the dashboard
-- might be sparse.

local config = require('aaag.config')

local M = {}

function M.check()
  local h = vim.health
  h.start('aaag')

  if vim.fn.has('nvim-0.10') == 1 then
    h.ok('Neovim 0.10+ (vim.system / vim.uv available)')
  else
    h.error('Neovim 0.10+ required', { 'aaag uses vim.system and vim.uv' })
  end

  if vim.fn.executable('claude') == 1 then
    h.ok('`claude` found on PATH')
  else
    h.error('`claude` not found on PATH',
      { 'Install the Claude Code CLI; summaries are unavailable without it' })
  end

  local sdir = config.opts.claude_dir .. '/sessions'
  if vim.uv.fs_stat(sdir) then
    h.ok('sessions directory: ' .. sdir)
  else
    h.warn('no sessions directory at ' .. sdir,
      { 'Start a Claude Code session, or set claude_dir in setup()' })
  end

  if vim.uv.fs_stat('/proc') then
    h.ok('/proc present -- liveness and terminal-jump use it')
  else
    h.info('no /proc (non-Linux) -- liveness uses signal-0, jump uses `ps`')
  end

  if pcall(require, 'telescope') then
    h.ok('telescope.nvim present -- :AaagPicker available')
  else
    h.info('telescope.nvim not found -- :AaagPicker disabled (dashboard still works)')
  end
end

return M

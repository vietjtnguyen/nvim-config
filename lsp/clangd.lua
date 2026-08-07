-- Enabled via vim.lsp.enable('clangd') in init.lua.
-- Install clangd separately (apt, an LLVM release, etc.) -- this only
-- tells Neovim how to run it.
--
-- A project can redirect clangd (e.g. into a build container) by dropping an
-- executable `.nvim-clangd` wrapper at its root. The root_dir search walks up
-- to the nearest one and uses THAT directory as the single LSP root -- so one
-- clangd serves the whole tree, which is what you want for a monorepo / ROS
-- workspace with a merged compile_commands.json sitting above the per-repo
-- .git dirs. cmd then launches the wrapper. With no wrapper, behaviour is the
-- conventional nearest-marker root + host clangd. See .nvim-clangd.example.

local markers = {
  '.clangd',
  '.clang-tidy',
  '.clang-format',
  'compile_commands.json',
  'compile_flags.txt',
  '.git',
}

local function cmd(dispatchers, config)
  local root = config.root_dir or vim.fn.getcwd()
  local wrapper = root .. '/.nvim-clangd'
  local prog = vim.fn.executable(wrapper) == 1 and { wrapper } or { 'clangd' }
  return vim.lsp.rpc.start(prog, dispatchers, { cwd = root })
end

return {
  cmd = cmd,
  filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda', 'proto' },
  -- Ancestor lookup: a top-level .nvim-clangd wins (single workspace root);
  -- otherwise fall back to the nearest conventional marker.
  root_dir = function(bufnr, on_dir)
    local fname = vim.api.nvim_buf_get_name(bufnr)
    local dir = fname ~= '' and vim.fs.dirname(fname) or vim.fn.getcwd()
    local wrapper = vim.fs.find(
      '.nvim-clangd', { upward = true, type = 'file', path = dir })[1]
    if wrapper then
      on_dir(vim.fs.dirname(wrapper))
    else
      on_dir(vim.fs.root(bufnr, markers) or dir)
    end
  end,
}

-- Enabled via vim.lsp.enable('clangd') in init.lua.
-- Install clangd separately (apt, an LLVM release, etc.) -- this only
-- tells Neovim how to run it.
--
-- cmd is a function so a project can transparently redirect clangd into a
-- container: if an executable .container-clangd wrapper exists at the project
-- root, use it (e.g. `docker exec -i <container> clangd ...`); otherwise fall
-- back to the host clangd. Container details stay in the project, not here.
-- See .container-clangd.example for a ready-to-copy docker/podman wrapper.
local function cmd(dispatchers, config)
  local root = config.root_dir or vim.fn.getcwd()
  local wrapper = root .. '/.container-clangd'
  local prog = vim.fn.executable(wrapper) == 1 and { wrapper } or { 'clangd' }
  return vim.lsp.rpc.start(prog, dispatchers, { cwd = root })
end

return {
  cmd = cmd,
  filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda', 'proto' },
  root_markers = {
    '.clangd',
    '.clang-tidy',
    '.clang-format',
    'compile_commands.json',
    'compile_flags.txt',
    '.git',
  },
}

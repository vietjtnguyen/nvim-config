-- Enabled via vim.lsp.enable('clangd') in init.lua.
-- Install clangd separately (apt, an LLVM release, etc.) -- this only
-- tells Neovim how to run it.
return {
  cmd = { 'clangd' },
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

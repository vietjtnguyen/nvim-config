-- Shared settings (also symlinked to ~/.vimrc for vanilla vim)
vim.cmd('source ~/.vimrc')

-- Plugins, managed by Neovim's built-in plugin manager (vim.pack, Neovim 0.12+).
-- Add entries here and restart; use :Pack update to update, :Pack remove to drop.
-- Pin each plugin to an exact commit for reproducibility: a fresh machine
-- gets the same version as here, not whatever is latest. Bump deliberately
-- with :Pack update, then copy the new SHA in.
vim.pack.add({
  -- tpope/vim-vinegar @ master, bb1bcdd (2022-01-11)
  { src = 'https://github.com/tpope/vim-vinegar', version = 'bb1bcddf43cfebe05eb565a84ab069b357d0b3d6' },
})

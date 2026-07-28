-- Shared settings (also symlinked to ~/.vimrc for vanilla vim)
vim.cmd('source ~/.vimrc')

-- Plugins, managed by Neovim's built-in plugin manager (vim.pack, Neovim 0.12+).
-- Add entries here and restart; use :Pack update to update, :Pack remove to drop.
--
-- Always pin `version` to a full commit SHA, never a branch or tag/range.
-- A tag can be retagged and a range trusts the author's semver correctness;
-- a SHA can't drift. This also makes nvim-pack-lock.json fully derivable from
-- this file, so it's gitignored rather than committed.
-- Bump deliberately with :Pack update, then copy the new SHA in below.
vim.pack.add({
  -- tpope/vim-vinegar @ master, bb1bcdd (2022-01-11)
  { src = 'https://github.com/tpope/vim-vinegar', version = 'bb1bcddf43cfebe05eb565a84ab069b357d0b3d6' },
})

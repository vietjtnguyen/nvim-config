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

-- LSP servers. Each has a config file at lsp/<name>.lua; enabling it here
-- is what actually starts the client. Core Neovim already provides the
-- attach keymaps (gra/gri/grn/grr/grt/gO/K/i_CTRL-S) and sets 'omnifunc',
-- 'tagfunc', 'formatexpr' on attach -- see :help lsp-defaults.
vim.lsp.enable('clangd')

-- Popup completion as you type (the default 'omnifunc' only offers manual
-- <C-x><C-o>). noselect avoids auto-inserting the first match; popup shows
-- the item's docs. Use <C-y> to accept, per :help complete_CTRL-Y.
vim.o.completeopt = 'menu,menuone,noselect,popup'
vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('lsp-completion', {}),
  callback = function(ev)
    local client = assert(vim.lsp.get_client_by_id(ev.data.client_id))
    if client:supports_method('textDocument/completion') then
      vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = true })
    end
  end,
})

-- Diagnostic navigation (not covered by Neovim's built-in LSP keymaps)
vim.keymap.set({ 'n', 'v', 'o' }, ']e', function() vim.diagnostic.jump({ count = 1 }) end, { desc = 'Next Diagnostic' })
vim.keymap.set({ 'n', 'v', 'o' }, '[e', function() vim.diagnostic.jump({ count = -1 }) end, { desc = 'Previous Diagnostic' })
vim.keymap.set({ 'n', 'v', 'o' }, 'ge', vim.diagnostic.open_float, { desc = 'Open Diagnostic' })
vim.keymap.set({ 'n', 'v', 'o' }, 'gE', vim.diagnostic.setloclist, { desc = 'Diagnostics to Loc List' })

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
  -- saghen/blink.cmp @ v1.10.2 tag (2026 stable v1 line; v2/main has breaking changes)
  { src = 'https://github.com/Saghen/blink.cmp', version = '9b189bb2a0e03412e0e901dfbd09904f86cd593c' },
  -- mikavilpas/blink-ripgrep.nvim @ v2.2.6 tag
  { src = 'https://github.com/mikavilpas/blink-ripgrep.nvim', version = '5ed7bac817777994cb80abccd052b73eb844166c' },
  -- mgalliou/blink-cmp-tmux @ HEAD (2026-07-16; no tagged releases)
  { src = 'https://github.com/mgalliou/blink-cmp-tmux', version = '112ddbf2e09d9cb4736de70dd01eb9654cf01d70' },
  -- joelazar/blink-calc @ HEAD (no tagged releases; smaller/less-established source)
  { src = 'https://github.com/joelazar/blink-calc', version = '1b75c20cbb21c95bf08694eed605fa0bdbbe5ca2' },
})

-- Completion, via blink.cmp -- not Neovim's native vim.lsp.completion, which
-- only offers an LSP source. blink.cmp implements its own LSP source rather
-- than building on vim.lsp.completion, so the two are never wired up together.
do
  local blink = require('blink.cmp')

  -- Advertise blink.cmp's enhanced capabilities (snippets, richer item
  -- kinds, etc.) to every LSP server, not just clangd.
  vim.lsp.config('*', { capabilities = blink.get_lsp_capabilities() })

  blink.setup({
    keymap = {
      preset = 'default',
      -- Old nvim-cmp muscle memory: <CR> confirms the selection; falls
      -- through to a normal newline when the menu isn't showing.
      ['<CR>'] = { 'select_and_accept', 'fallback' },
    },
    completion = {
      list = {
        selection = {
          preselect = true,
          -- Don't mutate the buffer while cycling candidates -- only on
          -- accept. Ghost text still previews the selection.
          auto_insert = false,
        },
      },
      ghost_text = { enabled = true },
    },
    signature = { enabled = true },
    sources = {
      default = { 'lsp', 'path', 'snippets', 'buffer', 'calc', 'ripgrep', 'tmux' },
      providers = {
        -- Defaults (path=3, snippets=-1, buffer=-3, lsp=0) put path above LSP
        -- on tied fuzzy-match scores. Push lsp above all of those so it wins.
        lsp = {
          score_offset = 5,
        },
        calc = {
          name = 'Calc',
          module = 'blink-calc',
        },
        ripgrep = {
          name = 'Ripgrep',
          module = 'blink-ripgrep',
          opts = { prefix_min_len = 3 },
        },
        tmux = {
          name = 'tmux',
          module = 'blink-cmp-tmux',
          opts = { panes = 'all' },
        },
      },
    },
    cmdline = {
      sources = function()
        local cmdtype = vim.fn.getcmdtype()
        if cmdtype == '/' or cmdtype == '?' then
          return { 'buffer', 'path', 'ripgrep', 'tmux' }
        end
        if cmdtype == ':' or cmdtype == '@' then
          return { 'cmdline', 'path' }
        end
        return {}
      end,
    },
  })
  vim.api.nvim_set_hl(0, 'BlinkCmpGhostText', { link = 'Comment' })
end

-- LSP servers. Each has a config file at lsp/<name>.lua; enabling it here
-- is what actually starts the client. Core Neovim already provides the
-- attach keymaps (gra/gri/grn/grr/grt/gO/K/i_CTRL-S) and sets 'omnifunc',
-- 'tagfunc', 'formatexpr' on attach -- see :help lsp-defaults.
vim.lsp.enable('clangd')

-- Diagnostic navigation (not covered by Neovim's built-in LSP keymaps)
vim.keymap.set({ 'n', 'v', 'o' }, ']e', function() vim.diagnostic.jump({ count = 1 }) end, { desc = 'Next Diagnostic' })
vim.keymap.set({ 'n', 'v', 'o' }, '[e', function() vim.diagnostic.jump({ count = -1 }) end, { desc = 'Previous Diagnostic' })
vim.keymap.set({ 'n', 'v', 'o' }, 'ge', vim.diagnostic.open_float, { desc = 'Open Diagnostic' })
vim.keymap.set({ 'n', 'v', 'o' }, 'gE', vim.diagnostic.setloclist, { desc = 'Diagnostics to Loc List' })

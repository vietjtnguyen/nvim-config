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
  -- tpope/vim-fugitive @ v3.7 tag
  { src = 'https://github.com/tpope/vim-fugitive', version = '96c1009fcf8ce60161cc938d149dd5a66d570756' },
  -- tpope/vim-surround @ v2.2 tag
  { src = 'https://github.com/tpope/vim-surround', version = 'aeb933272e72617f7c4d35e1f003be16836b948d' },
  -- tpope/vim-unimpaired @ v2.1 tag
  { src = 'https://github.com/tpope/vim-unimpaired', version = 'efdc6475f7ea789346716dabf9900ac04ee8604a' },
  -- nvim-mini/mini.trailspace @ v0.9.0 tag (modern Lua replacement for
  -- vim-better-whitespace; standalone install, not the full mini.nvim bundle)
  { src = 'https://github.com/nvim-mini/mini.trailspace', version = 'c41ab1035d184ff20c1aebd76639320c055afebe' },
  -- MagicDuck/grug-far.nvim @ 1.6.76 tag (modern replacement for
  -- nvim-spectre; ripgrep + ast-grep backed find/replace)
  { src = 'https://github.com/MagicDuck/grug-far.nvim', version = '6e05398cf6cad05b3fb46569db96b1ccfcbbd402' },
  -- nvim-treesitter/nvim-treesitter @ HEAD (2026-07; post-rewrite "main"
  -- branch releases continuously, no meaningful tags -- the v0.9.x tags
  -- are leftovers from the pre-rewrite branch)
  { src = 'https://github.com/nvim-treesitter/nvim-treesitter', version = '61df84986b4b4ec469ee745a182e433d49f8c27e' },
  -- ellisonleao/gruvbox.nvim @ v2.0.0 tag
  { src = 'https://github.com/ellisonleao/gruvbox.nvim', version = 'ca36abf47f1d0ad577b464980a3d4af51bb26203' },
  -- folke/tokyonight.nvim @ v4.9.0 tag
  { src = 'https://github.com/folke/tokyonight.nvim', version = '19f39b53ef5e148bf94ea3696df36175af7e31e6' },
  -- navarasu/onedark.nvim @ v1.0.3 tag
  { src = 'https://github.com/navarasu/onedark.nvim', version = '631085064d202d07e4b677f11dcd24383f5c6fd9' },
})

-- Configured but not activated (github_dark is the default below); switch
-- to it with :colorscheme onedark.
require('onedark').setup({
  style = 'cool',
  transparent = true,
  term_colors = true,
  ending_tildes = false,
  code_style = {
    comments = 'none',
    keywords = 'none',
    functions = 'none',
    strings = 'none',
    variables = 'none',
  },
  diagnostics = {
    darker = true,
    undercurl = true,
    background = true,
  },
})

-- Treesitter-based syntax highlighting. vim.treesitter.start() disables
-- legacy regex :syntax for that buffer automatically (see
-- runtime/lua/vim/treesitter/highlighter.lua) -- this is what actually
-- avoids the classic "syntax plugin fighting treesitter" conflict.
-- Note: the tree-sitter grammar/parser is named 'bash', but Neovim's
-- filetype for bash/sh scripts is 'sh' (even for a #!/bin/bash shebang).
require('nvim-treesitter').install({ 'cpp', 'python', 'bash' })
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'cpp', 'python', 'sh' },
  callback = function() vim.treesitter.start() end,
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
        -- Self-written (lua/pycalc.lua): shells out to `python3 -c` with
        -- `from math import *` and prints the expression before the cursor.
        calc = {
          name = 'Calc',
          module = 'pycalc',
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

-- Highlight trailing whitespace; :lua MiniTrailspace.trim() to strip it
-- (not automatic on save, matching vim-better-whitespace's own default).
require('mini.trailspace').setup()

-- Find/replace across the project. :GrugFar to open; no required options.
require('grug-far').setup()

-- Diagnostic float/loclist (next/prev jump is already ]d/[d, a core default;
-- ]e/[e are left alone for vim-unimpaired's line-exchange mapping)
vim.keymap.set({ 'n', 'v', 'o' }, 'ge', vim.diagnostic.open_float, { desc = 'Open Diagnostic' })
vim.keymap.set({ 'n', 'v', 'o' }, 'gE', vim.diagnostic.setloclist, { desc = 'Diagnostics to Loc List' })

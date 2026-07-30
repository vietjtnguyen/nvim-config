--------------------------------------------------------------------------------
-- Shared vim/nvim settings
--------------------------------------------------------------------------------
-- Shared settings (also symlinked to ~/.vimrc for vanilla vim)
vim.cmd('source ~/.vimrc')

--------------------------------------------------------------------------------
-- Highlight on yank
--------------------------------------------------------------------------------
-- Briefly flash the yanked region so it's clear what got copied. IncSearch is
-- a high-contrast group, so the flash stays visible over 'cursorline'.
vim.api.nvim_create_autocmd('TextYankPost', {
  callback = function() vim.hl.on_yank({ higroup = 'IncSearch', timeout = 200 }) end,
})

--------------------------------------------------------------------------------
-- Plugins
--------------------------------------------------------------------------------
-- Plugins, managed by Neovim's built-in plugin manager (vim.pack, Neovim
-- 0.12+). Add entries here and restart; use :Pack update to update, :Pack
-- remove to drop.
--
-- Always pin `version` to a full commit SHA, never a branch or tag/range. A tag
-- can be retagged and a range trusts the author's semver correctness; a SHA
-- can't drift. This also makes nvim-pack-lock.json fully derivable from this
-- file, so it's gitignored rather than committed. Bump deliberately with :Pack
-- update, then copy the new SHA in below.
vim.pack.add({
  -- tpope/vim-vinegar @ master, bb1bcdd (2022-01-11)
  { src = 'https://github.com/tpope/vim-vinegar', version = 'bb1bcddf43cfebe05eb565a84ab069b357d0b3d6' },
  -- saghen/blink.cmp @ v1.10.2 tag (2026 stable v1 line; v2/main has breaking
  -- changes)
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
  -- MagicDuck/grug-far.nvim @ 1.6.76 tag (modern replacement for nvim-spectre;
  -- ripgrep + ast-grep backed find/replace)
  { src = 'https://github.com/MagicDuck/grug-far.nvim', version = '6e05398cf6cad05b3fb46569db96b1ccfcbbd402' },
  -- nvim-treesitter/nvim-treesitter @ HEAD (2026-07; post-rewrite "main" branch
  -- releases continuously, no meaningful tags -- the v0.9.x tags are leftovers
  -- from the pre-rewrite branch)
  { src = 'https://github.com/nvim-treesitter/nvim-treesitter', version = '61df84986b4b4ec469ee745a182e433d49f8c27e' },
  -- SuperJappie08/tree-sitter-ros-interface @ HEAD (no tags). A treesitter
  -- grammar for ROS .msg/.srv/.action files; not in nvim-treesitter's
  -- registry, so it's compiled and registered manually in the Treesitter
  -- section below.
  { src = 'https://github.com/SuperJappie08/tree-sitter-ros-interface', version = '9eed3703424441e1c0fec97cb911cfa199bbeef5' },
  -- ellisonleao/gruvbox.nvim @ v2.0.0 tag
  { src = 'https://github.com/ellisonleao/gruvbox.nvim', version = 'ca36abf47f1d0ad577b464980a3d4af51bb26203' },
  -- folke/tokyonight.nvim @ v4.9.0 tag
  { src = 'https://github.com/folke/tokyonight.nvim', version = '19f39b53ef5e148bf94ea3696df36175af7e31e6' },
  -- navarasu/onedark.nvim @ v1.0.3 tag
  { src = 'https://github.com/navarasu/onedark.nvim', version = '631085064d202d07e4b677f11dcd24383f5c6fd9' },
  -- projekt0n/github-nvim-theme @ v1.1.2 tag
  { src = 'https://github.com/projekt0n/github-nvim-theme', version = 'd26a5f523b292c80cf396ed40623534bbc8756be' },
  -- nvim-lua/plenary.nvim @ v0.1.4 tag (telescope.nvim dependency)
  { src = 'https://github.com/nvim-lua/plenary.nvim', version = '50012918b2fc8357b87cff2a7f7f0446e47da174' },
  -- nvim-telescope/telescope.nvim @ v0.2.2 tag
  { src = 'https://github.com/nvim-telescope/telescope.nvim', version = '5255aa27c422de944791318024167ad5d40aad20' },
  -- nvim-telescope/telescope-fzf-native.nvim @ HEAD (no tagged releases)
  { src = 'https://github.com/nvim-telescope/telescope-fzf-native.nvim', version = 'b25b749b9db64d375d782094e2b9dce53ad53a40' },
  -- debugloop/telescope-undo.nvim @ HEAD (no tagged releases; last pushed
  -- 2025-01-31 -- stale but still functional, no real equivalent elsewhere)
  { src = 'https://github.com/debugloop/telescope-undo.nvim', version = '928d0c2dc9606e01e2cc547196f48d2eaecf58e5' },
  -- aaronik/treewalker.nvim @ HEAD (no tagged releases). Picked over tree-
  -- climber.nvim and jump-tag, both of which throw errors on this Neovim: they
  -- call into nvim-treesitter's old pre-rewrite helper modules (nvim-
  -- treesitter.parsers / .ts_utils), removed when nvim-treesitter was
  -- rewritten. Confirmed by actually calling their functions, not just checking
  -- they installed. treewalker uses core vim.treesitter directly, no nvim-
  -- treesitter dependency at all.
  { src = 'https://github.com/aaronik/treewalker.nvim', version = '228f9cd84e7ee45c72e4c9c5c0523e50f13ad520' },
  -- folke/which-key.nvim @ v3.17.0 tag
  { src = 'https://github.com/folke/which-key.nvim', version = 'fcbf4eea17cb299c02557d576f0d568878e354a4' },
})

--------------------------------------------------------------------------------
-- Treesitter navigation (treewalker.nvim)
--------------------------------------------------------------------------------
-- Move the cursor through the treesitter tree without selecting (complements
-- core's an/in/]n/[n/]N/[N, which are selection-oriented -- see :help
-- treesitter-incremental-selection). Ctrl+Arrow to match the existing Alt+Arrow
-- pane-nav convention in vimrc. treewalker's own Up/Down/Left/Right names mean
-- prev-sibling/next-sibling/ancestor/child (an outline-indent metaphor);
-- remapped here to the more direct up=parent/down=child compass metaphor for
-- the arrow keys specifically.
require('treewalker').setup()

-- After each move, flash all four *next-possible* destinations (not just the
-- node just landed on, which treewalker already flashes itself) so the next
-- Ctrl+Arrow's target is visible before pressing it. Reaches into
-- treewalker.anchor's find_* functions -- the same lookups its own move
-- commands use internally -- since there's no public "peek" API for this.
-- Undocumented/internal, so a future treewalker update could rename or
-- restructure this without warning; verified against the installed version.
do
  local function preview_next_moves()
    local anchor = require('treewalker.anchor')
    local opts = require('treewalker').opts
    local current = anchor.current()
    if not current then return end

    local ns = vim.api.nvim_create_namespace('treewalker-preview')
    vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)

    -- find_out=parent, find_in=child, find_up=prev sibling, find_down=next
    -- sibling (treewalker's outline-indent naming) -- mapped here to the
    -- up=parent/down=child/left,right=siblings compass keys below.
    local directions = {
      { find = 'find_out', hl = 'DiffDelete' }, -- Ctrl-Up (parent)
      { find = 'find_in', hl = 'DiffText' }, -- Ctrl-Down (child)
      { find = 'find_up', hl = 'DiffAdd' }, -- Ctrl-Left (prev sibling)
      { find = 'find_down', hl = 'DiffChange' }, -- Ctrl-Right (next sibling)
    }
    local lines = require('treewalker.lines')
    for _, d in ipairs(directions) do
      local target = anchor[d.find](current)
      if target then
        -- Just the single cell the cursor will actually land on (matching
        -- operations.jump_to_line_start: first non-whitespace column of
        -- target.row), not the destination node's whole text range.
        local line = lines.get_line(target.row) or ''
        local col0 = lines.get_start_col(line) - 1
        local row0 = target.row - 1
        vim.hl.range(0, ns, d.hl, { row0, col0 }, { row0, col0 }, { inclusive = true })
      end
    end

    vim.defer_fn(function()
      vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
    end, opts.highlight_duration or 250)
  end

  local function move_and_preview(cmd)
    return function()
      vim.cmd('Treewalker ' .. cmd)
      vim.schedule(preview_next_moves)
    end
  end

  vim.keymap.set({ 'n', 'v' }, '<C-Left>', move_and_preview('Up'), { desc = 'Treesitter: prev sibling' })
  vim.keymap.set({ 'n', 'v' }, '<C-Right>', move_and_preview('Down'), { desc = 'Treesitter: next sibling' })
  vim.keymap.set({ 'n', 'v' }, '<C-Up>', move_and_preview('Left'), { desc = 'Treesitter: parent' })
  vim.keymap.set({ 'n', 'v' }, '<C-Down>', move_and_preview('Right'), { desc = 'Treesitter: child' })
end

--------------------------------------------------------------------------------
-- Telescope (fuzzy finder)
--------------------------------------------------------------------------------
-- Telescope: fuzzy finder / picker over files, buffers, git, LSP, etc.
require('telescope').setup({})

-- telescope-fzf-native has no vim.pack build hook (unlike lazy.nvim's `build =
-- 'make'`), so compile it here if the .so isn't there yet.
do
  local plug = vim.pack.get({ 'telescope-fzf-native.nvim' })[1]
  if plug and vim.fn.glob(plug.path .. '/build/libfzf*') == '' then
    local res = vim.system({ 'make', '-C', plug.path }):wait()
    if res.code ~= 0 then
      vim.notify('telescope-fzf-native build failed: ' .. (res.stderr or ''), vim.log.levels.ERROR)
    end
  end
end
require('telescope').load_extension('fzf')
require('telescope').load_extension('undo')

for _, m in ipairs({
  { '<Space>b', 'buffers', 'Buffers' },
  { '<Space>e', 'diagnostics', 'Diagnostics' },
  { '<Space>F', 'current_buffer_fuzzy_find', 'Buffer Fuzzy Find' },
  { '<Space>f', 'live_grep', 'Live Grep' },
  { '<Space>gb', 'git_branches', 'Git Branches' },
  { '<Space>gC', 'git_bcommits', 'Git Commits (buffer)' },
  { '<Space>gc', 'git_commits', 'Git Commits' },
  { '<Space>gs', 'git_status', 'Git Status' },
  { '<Space>J', 'jumplist', 'Jump List' },
  { '<Space>k', 'keymaps', 'Key Maps' },
  { '<Space>K', 'man_pages', 'Man Pages' },
  { '<Space>L', 'loclist', 'Location List' },
  { '<Space>p', 'find_files', 'Find Files' },
  { '<Space>P', 'oldfiles', 'Recent Files' },
  { '<Space>q', 'builtin', 'Telescope Built In' },
  { '<Space>Q', 'quickfix', 'Quick Fix List' },
  { '<Space>T', 'treesitter', 'Treesitter' },
}) do
  local lhs, builtin, desc = m[1], m[2], m[3]
  vim.keymap.set({ 'n', 'v', 'o' }, lhs, function() require('telescope.builtin')[builtin]() end, { desc = desc })
end

-- Project-wide LSP symbol search. Deliberately lsp_dynamic_workspace_symbols,
-- not lsp_workspace_symbols: the static version sends one empty-query request
-- up front and filters that fixed list locally, which can look
-- broken/incomplete if the server returns little for an empty query. The
-- dynamic version re-sends workspace/symbol with the actual typed text on every
-- keystroke, so the server does the real project-wide search.
vim.keymap.set({ 'n', 'v', 'o' }, '<Space>s', function()
  require('telescope.builtin').lsp_dynamic_workspace_symbols()
end, { desc = 'Workspace Symbols' })
vim.keymap.set({ 'n', 'v', 'o' }, '<Space>t', function()
  require('telescope.builtin').lsp_dynamic_workspace_symbols({
    symbols = { 'class', 'struct', 'interface', 'enum' },
  })
end, { desc = 'Workspace Symbols: Types' })
vim.keymap.set({ 'n', 'v', 'o' }, '<Space>m', function()
  require('telescope.builtin').lsp_dynamic_workspace_symbols({
    symbols = { 'function', 'method' },
  })
end, { desc = 'Workspace Symbols: Functions/Methods' })

--------------------------------------------------------------------------------
-- Colorschemes
--------------------------------------------------------------------------------
-- Configured but not activated (github_dark is the default below); switch to it
-- with :colorscheme onedark.
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

-- Default colorscheme.
require('github-theme').setup({
  options = {
    hide_nc_statusline = false,
    transparent = true,
    styles = {
      comments = 'NONE',
      functions = 'NONE',
      keywords = 'bold',
      variables = 'NONE',
      conditionals = 'NONE',
      constants = 'NONE',
      numbers = 'NONE',
      operators = 'NONE',
      strings = 'NONE',
      types = 'bold',
    },
  },
})
vim.cmd.colorscheme('github_dark')

--------------------------------------------------------------------------------
-- Treesitter syntax highlighting
--------------------------------------------------------------------------------
-- Treesitter-based syntax highlighting. vim.treesitter.start() disables legacy
-- regex :syntax for that buffer automatically (see
-- runtime/lua/vim/treesitter/highlighter.lua) -- this is what actually avoids
-- the classic "syntax plugin fighting treesitter" conflict. Note: the tree-
-- sitter grammar/parser is named 'bash', but Neovim's filetype for bash/sh
-- scripts is 'sh' (even for a #!/bin/bash shebang). Markdown needs two
-- parsers -- 'markdown' (blocks) and 'markdown_inline' (emphasis, links, code
-- spans); fenced code blocks are highlighted by injection via the parsers
-- above.
require('nvim-treesitter').install({
  'bash', 'c', 'cmake', 'cpp', 'css', 'html', 'javascript', 'json',
  'markdown', 'markdown_inline', 'python', 'rust', 'tsx', 'typescript',
})
-- Filetype names, not parser names (they differ for a few: the 'bash' parser
-- highlights the 'sh' filetype; markdown_inline has no filetype of its own, it
-- is injected by the markdown parser). pcall so a not-yet-compiled parser
-- (install() runs async on first launch) fails quietly instead of erroring;
-- it highlights once the parser is built and the buffer is reopened.
vim.api.nvim_create_autocmd('FileType', {
  pattern = {
    'c', 'cmake', 'cpp', 'css', 'html', 'javascript', 'json',
    'markdown', 'python', 'rosmsg', 'rust', 'sh',
    'typescript', 'typescriptreact',
  },
  callback = function() pcall(vim.treesitter.start) end,
})

-- The .tsx filetype is 'typescriptreact' but its parser is named 'tsx'; map it
-- so vim.treesitter.start() finds the parser. (.ts's 'typescript' filetype
-- matches its parser name directly.)
vim.treesitter.language.register('tsx', 'typescriptreact')

-- ROS interface files (.msg/.srv/.action) via SuperJappie08/tree-sitter-ros-
-- interface, which isn't in nvim-treesitter's registry. Detect the filetype,
-- then compile the parser to parser/ros_interface.so and copy its queries to
-- queries/ros_interface/ -- both derived from the pinned grammar (hence
-- gitignored) -- and map the 'rosmsg' filetype to the parser. The FileType
-- autocmd above already starts treesitter for 'rosmsg'.
vim.filetype.add({
  extension = { msg = 'rosmsg', srv = 'rosmsg', action = 'rosmsg' },
})
do
  local plug = vim.pack.get({ 'tree-sitter-ros-interface' })[1]
  if plug then
    local cfg = vim.fn.stdpath('config')
    local so = cfg .. '/parser/ros_interface.so'
    if vim.fn.filereadable(so) == 0 then
      vim.fn.mkdir(cfg .. '/parser', 'p')
      local res = vim.system({
        'cc', '-o', so, '-shared', '-fPIC', '-Os',
        '-I', plug.path .. '/src', plug.path .. '/src/parser.c',
      }):wait()
      if res.code ~= 0 then
        vim.notify('ros_interface parser build failed: ' .. (res.stderr or ''),
          vim.log.levels.ERROR)
      end
    end
    local qdir = cfg .. '/queries/ros_interface'
    if vim.fn.isdirectory(qdir) == 0 then
      vim.fn.mkdir(qdir, 'p')
      for _, name in ipairs({ 'highlights.scm', 'injections.scm' }) do
        local src = plug.path .. '/queries/' .. name
        if vim.fn.filereadable(src) == 1 then
          vim.fn.writefile(vim.fn.readfile(src), qdir .. '/' .. name)
        end
      end
    end
    vim.treesitter.language.register('ros_interface', 'rosmsg')
  end
end

-- github_dark colors fenced code like normal text, so untagged blocks don't
-- stand out (tagged blocks get injected syntax). Give the block a subtle
-- background (Pmenu's, matching the popup panels and tracking the theme);
-- leave fg alone so injected syntax and plain text keep their colors. Note:
-- treesitter backgrounds only cover the text, not full line width. Re-applied
-- on ColorScheme, which clears it.
do
  local function set_code_hl()
    local pmenu = vim.api.nvim_get_hl(0, { name = 'Pmenu', link = false })
    vim.api.nvim_set_hl(0, '@markup.raw.block', { bg = pmenu.bg })
  end
  set_code_hl()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('markdown-code-hl', { clear = true }),
    callback = set_code_hl,
  })
end

--------------------------------------------------------------------------------
-- Completion (blink.cmp)
--------------------------------------------------------------------------------
-- Completion, via blink.cmp -- not Neovim's native vim.lsp.completion, which
-- only offers an LSP source. blink.cmp implements its own LSP source rather
-- than building on vim.lsp.completion, so the two are never wired up together.
do
  local blink = require('blink.cmp')

  -- Advertise blink.cmp's enhanced capabilities (snippets, richer item kinds,
  -- etc.) to every LSP server, not just clangd.
  vim.lsp.config('*', { capabilities = blink.get_lsp_capabilities() })

  blink.setup({
    keymap = {
      preset = 'default',
      -- Old nvim-cmp muscle memory: <CR> confirms the selection; falls through
      -- to a normal newline when the menu isn't showing.
      ['<CR>'] = { 'select_and_accept', 'fallback' },
    },
    completion = {
      list = {
        selection = {
          preselect = true,
          -- Don't mutate the buffer while cycling candidates -- only on accept.
          -- Ghost text still previews the selection.
          auto_insert = false,
        },
      },
      ghost_text = { enabled = true },
    },
    signature = { enabled = true, window = { border = 'none' } },
    sources = {
      default = { 'lsp', 'path', 'snippets', 'buffer', 'calc', 'ripgrep', 'tmux' },
      providers = {
        -- Defaults (path=3, snippets=-1, buffer=-3, lsp=0) put path above LSP
        -- on tied fuzzy-match scores. Push lsp above all of those so it wins.
        lsp = {
          score_offset = 5,
        },
        -- Self-written (lua/pycalc.lua): shells out to `python3 -c` with `from
        -- math import *` and prints the expression before the cursor.
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
  -- blink's float highlights fall back to NormalFloat, which the transparent
  -- theme leaves with no background -- so the signature popup shows the code
  -- behind it. Give it the completion menu's solid look (Pmenu), emphasize the
  -- active parameter, and dim the ghost text. Re-applied on ColorScheme, which
  -- clears these.
  local function blink_hl()
    vim.api.nvim_set_hl(0, 'BlinkCmpGhostText', { link = 'Comment' })
    vim.api.nvim_set_hl(0, 'BlinkCmpSignatureHelp', { link = 'Pmenu' })
    vim.api.nvim_set_hl(0, 'BlinkCmpSignatureHelpBorder', { link = 'Pmenu' })
    vim.api.nvim_set_hl(0, 'BlinkCmpSignatureHelpActiveParameter',
      { bold = true, underline = true })
  end
  blink_hl()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('blink-hl', { clear = true }),
    callback = blink_hl,
  })
end

--------------------------------------------------------------------------------
-- LSP servers
--------------------------------------------------------------------------------
-- Each has a config file at lsp/<name>.lua; enabling it here is what actually
-- starts the client. Core Neovim already provides the attach keymaps
-- (gra/gri/grn/grr/grt/gO/K/i_CTRL-S) and sets 'omnifunc', 'tagfunc',
-- 'formatexpr' on attach -- see :help lsp-defaults.
vim.lsp.enable('clangd')

-- Core leaves definition/declaration to the tag mechanism (<C-]> via
-- 'tagfunc'); add discoverable keys in the same gr* namespace. grd/grD, not
-- gd/gD, so Vim's built-in gd/gD (in-file declaration search) still work.
vim.keymap.set('n', 'grd', vim.lsp.buf.definition, { desc = 'Definition' })
vim.keymap.set('n', 'grD', vim.lsp.buf.declaration, { desc = 'Declaration' })

-- Inlay hints (parameter names, deduced types) off by default -- grI toggles
-- them globally. Kept in the gr* namespace so which-key groups it under "lsp".
vim.keymap.set('n', 'grI', function()
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
end, { desc = 'Toggle Inlay Hints' })

-- github_dark's LspInlayHint bg is too faint against a transparent background,
-- so hints read like code. Restyle: dim (Comment) italic text on the Visual
-- background, re-applied on ColorScheme since a switch clears it.
do
  local function set_inlay_hl()
    local vis = vim.api.nvim_get_hl(0, { name = 'Visual', link = false })
    local com = vim.api.nvim_get_hl(0, { name = 'Comment', link = false })
    vim.api.nvim_set_hl(0, 'LspInlayHint', { fg = com.fg, bg = vis.bg, italic = true })
  end
  set_inlay_hl()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('inlay-hint-hl', { clear = true }),
    callback = set_inlay_hl,
  })
end

--------------------------------------------------------------------------------
-- Reference highlighting (lua/navigate_references.lua)
--------------------------------------------------------------------------------
-- Self-written: highlight every use of the symbol under the cursor in the
-- current file (semantic, via the LSP document highlight), debounced on cursor
-- idle and cleared on move. ]r / [r hop between those same uses without
-- touching the quickfix list. See the module for details.
require('navigate_references').setup()
vim.keymap.set('n', ']r', function() require('navigate_references').jump(true) end, { desc = 'Next reference' })
vim.keymap.set('n', '[r', function() require('navigate_references').jump(false) end, { desc = 'Prev reference' })

--------------------------------------------------------------------------------
-- Call hints (lua/callhints.lua)
--------------------------------------------------------------------------------
-- Self-written: virtual text at each function's signature line showing how many
-- in-file vs out-of-file callers it has, derived from the LSP call hierarchy.
-- Off by default; :CallHints (or <Space>h) toggles it per buffer, and it
-- refreshes on save.
require('callhints').setup()
vim.keymap.set({ 'n', 'v', 'o' }, '<Space>h', function()
  require('callhints').toggle()
end, { desc = 'Toggle Call Hints' })

--------------------------------------------------------------------------------
-- Whitespace (mini.trailspace)
--------------------------------------------------------------------------------
-- Highlight trailing whitespace; :lua MiniTrailspace.trim() to strip it (not
-- automatic on save, matching vim-better-whitespace's own default).
require('mini.trailspace').setup()

--------------------------------------------------------------------------------
-- Find & replace (grug-far.nvim)
--------------------------------------------------------------------------------
-- Find/replace across the project. :GrugFar to open; no required options.
require('grug-far').setup()

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------
-- Float/loclist (next/prev jump is already ]d/[d, a core default; ]e/[e are
-- left alone for vim-unimpaired's line-exchange mapping)
vim.keymap.set({ 'n', 'v', 'o' }, 'ge', vim.diagnostic.open_float, { desc = 'Open Diagnostic' })
vim.keymap.set({ 'n', 'v', 'o' }, 'gE', vim.diagnostic.setloclist, { desc = 'Diagnostics to Loc List' })

-- Cycle the inline diagnostic display with <Space>E: off -> current line ->
-- everywhere. virtual_text stays off in all three (it duplicates
-- virtual_lines); signs and underline are untouched. Starts on current-line:
-- the full message where the cursor is, quiet elsewhere.
do
  local modes = {
    { 'off', { virtual_text = false, virtual_lines = false } },
    { 'current line', { virtual_text = false, virtual_lines = { current_line = true } } },
    { 'everywhere', { virtual_text = false, virtual_lines = true } },
  }
  local i = 2
  local function apply(notify)
    vim.diagnostic.config(modes[i][2])
    if notify then vim.notify('Diagnostics: ' .. modes[i][1]) end
  end
  apply(false)
  vim.keymap.set({ 'n', 'v', 'o' }, '<Space>E', function()
    i = i % #modes + 1
    apply(true)
  end, { desc = 'Cycle Diagnostic Display' })
end

--------------------------------------------------------------------------------
-- Which-key (keymap discovery)
--------------------------------------------------------------------------------
-- Pop up the available follow-on keys after a prefix (e.g. <Space>), read from
-- the `desc` set on each keymap. icons.mappings is off: no icon provider
-- (mini.icons / nvim-web-devicons) is installed, so keep the menu text-only.
require('which-key').setup({
  icons = { mappings = false },
})

-- Group the multi-level prefixes and give the core LSP defaults (gr*, gO, K)
-- friendly names -- their built-in descriptions are raw like
-- "vim.lsp.buf.rename()". desc-only entries relabel the which-key popup
-- without creating mappings, so K keeps its default (buffer-local) behavior.
require('which-key').add({
  { '<Space>g', group = 'git' },
  { 'gr', group = 'lsp' },
  { 'gra', desc = 'Code Action', mode = { 'n', 'x' } },
  { 'gri', desc = 'Implementations' },
  { 'grn', desc = 'Rename' },
  { 'grr', desc = 'References' },
  { 'grt', desc = 'Type Definition' },
  { 'grx', desc = 'Run CodeLens' },
  { 'gO', desc = 'Document Symbols' },
  { 'K', desc = 'Hover Docs' },
})

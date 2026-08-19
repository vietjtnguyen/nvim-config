" Show a color column if the text exceeds a width of 80 characters
set colorcolumn=81
" Hard-wrap at 80 characters (used by formatoptions' c/r/o flags and gq)
set textwidth=80
" Preserve indents when going to new line
set autoindent
" Infer indent style (tabs/spaces) and copy indent style
set copyindent
" Highlight the current line
set cursorline
" Use spaces instead of tabs
set expandtab
" Fold based on language syntax
set foldmethod=syntax
" Continue comments onto new lines and auto-wrap them at textwidth (c/r/o), but
" do NOT auto-hard-wrap regular text as you type: the default 't' flag mangles
" long commands and prose. gq still reflows a paragraph at textwidth on demand.
set formatoptions+=cro
set formatoptions-=t
" Remember more command-line and search history
set history=9999
" Highlight all search matches
set hlsearch
" Jump to the first match as you type a search
set incsearch
" Always show the status line
set laststatus=2
" Soft break (soft wrap) lines based on words instead of characters
set linebreak
" Enable the mouse in all modes
set mouse=a
" Show line numbers
set number
" Keep 10 lines of context above/below the cursor when scrolling
set scrolloff=10
" Round indents to a multiple of shiftwidth with < and >
set shiftround
" Indent width for auto-indent and << / >>
set shiftwidth=2
" Briefly jump to a bracket's match when it's inserted
set showmatch
" Use shiftwidth, not tabstop, for a <Tab> at the start of a line
set smarttab
" Allow opening up to 50 tabs at once
set tabpagemax=50
" Display existing tabs as 2 spaces wide
set tabstop=2
" Remember more undo history
set undolevels=9999
" Allow the cursor past the end of a line in visual block mode
set virtualedit=block
" Disable the bell entirely, audible and visual
set belloff=all
" Ignore these in command-line completion (:e, :find, netrw, etc.)
set wildignore=*.swp,*.bak,*.pyc,*.class
" Allow windows to shrink to zero height
set winminheight=0

" Hybrid line numbers: absolute on the cursor line, relative elsewhere.
" Drop to absolute-only while typing, since relative counts don't matter then.
set relativenumber
augroup numbertoggle
  autocmd!
  autocmd InsertEnter * set norelativenumber
  autocmd InsertLeave * set relativenumber
augroup END

" Get rid of an unnecessary shift (left out of Operator-pending mode so
" d;/y;/c; etc. still repeat the last f/t/F/T find-motion)
nnoremap ; :
xnoremap ; :

" Quickly change from pane to pane
tnoremap <A-Left> <C-\><C-n><C-w>h
tnoremap <A-Down> <C-\><C-n><C-w>j
tnoremap <A-Up> <C-\><C-n><C-w>k
tnoremap <A-Right> <C-\><C-n><C-w>l
noremap <A-Left> <C-w>h
noremap <A-Down> <C-w>j
noremap <A-Up> <C-w>k
noremap <A-Right> <C-w>l
inoremap <A-Left> <Esc><C-w>h
inoremap <A-Down> <Esc><C-w>j
inoremap <A-Up> <Esc><C-w>k
inoremap <A-Right> <Esc><C-w>l

" Remap Leader to comma, easy to reach
let mapleader=","

" Clear search highlights
nmap <silent> <Leader>/ :nohlsearch<CR>

" Create an easier mapping for getting out of terminal mode
" https://vi.stackexchange.com/a/6966
tnoremap <Leader>. <C-\><C-n>

" Quickly create a new terminal in a new tab
tnoremap <Leader>c <C-\><C-n>:tab new<CR>:term<CR>
noremap <Leader>c :tab new<CR>:term<CR>

" Quickly create a new terminal in a vertical split
tnoremap <Leader>% <C-\><C-n>:vsp<CR>:term<CR>
noremap <Leader>% :vsp<CR>:term<CR>

" Quickly create a new terminal in a horizontal split
tnoremap <Leader>" <C-\><C-n>:sp<CR>:term<CR>
noremap <Leader>" :sp<CR>:term<CR>

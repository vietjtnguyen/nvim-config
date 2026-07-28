" Show a color column if the text exceeds a width of 80 characters
set colorcolumn=81

" Hard-wrap at 80 characters (used by formatoptions' c/r/o flags and gq)
set textwidth=80

" Preserve indents when going to new line
set autoindent

" Infer indent style (tabs/spaces) and copy indent style
set copyindent

set cursorline
set expandtab
set foldmethod=syntax
set formatoptions+=cro
set history=9999
set hlsearch
set incsearch

" Always show the status line
set laststatus=2

" Soft break (soft wrap) lines based on words instead of characters
set linebreak

set mouse=a
set number
set scrolloff=10
set shiftround
set shiftwidth=2
set showmatch
set smarttab
set tabpagemax=50
set tabstop=2
set undolevels=9999
set virtualedit=block
set belloff=all
set wildignore=*.swp,*.bak,*.pyc,*.class
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

-- Neovim's built-in markdown ftplugin adds 't' to 'formatoptions', which
-- auto-hard-wraps prose at 'textwidth' (80) as you type. Drop 't' (and 'c', so
-- nothing comment-detected wraps either) to turn that off. This lives in
-- after/ftplugin so it runs after the built-in ftplugin that adds 't'.
-- 'textwidth' is left at 80, so gq still reflows a paragraph on demand.
vim.opt_local.formatoptions:remove('t')
vim.opt_local.formatoptions:remove('c')

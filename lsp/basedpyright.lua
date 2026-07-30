-- Enabled via the guarded vim.lsp.enable loop in init.lua. Install with
-- `uv tool install basedpyright` (or `pipx install basedpyright`); the pip
-- wheel bundles the server, so `basedpyright-langserver` just runs.
--
-- Provides types, completion, hover, go-to-def, and inlay hints (toggle with
-- grI). Pairs with ruff, which owns linting and formatting -- see lsp/ruff.lua.
return {
  cmd = { 'basedpyright-langserver', '--stdio' },
  filetypes = { 'python' },
  root_markers = {
    'pyproject.toml',
    'setup.py',
    'setup.cfg',
    'requirements.txt',
    'Pipfile',
    'pyrightconfig.json',
    '.git',
  },
  settings = {
    basedpyright = {
      analysis = {
        -- Balanced strictness: real type errors without flooding untyped /
        -- third-party-heavy (e.g. ROS) code.
        typeCheckingMode = 'standard',
        -- Only diagnose open files, not the whole project (lighter).
        diagnosticMode = 'openFilesOnly',
        autoImportCompletions = true,
        inlayHints = {
          variableTypes = true,
          functionReturnTypes = true,
          callArgumentNames = true,
          genericTypes = false,
        },
      },
    },
  },
}

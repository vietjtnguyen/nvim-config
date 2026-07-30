-- Enabled via the guarded vim.lsp.enable loop in init.lua. Install with
-- `uv tool install ruff` (or `pipx install ruff`).
--
-- Linting, formatting (ruff format, black-compatible), and import organization
-- for Python. Formatting is invoked on demand with grF (vim.lsp.buf.format);
-- basedpyright can't format, so grF unambiguously uses ruff here. Lint/format
-- rules come from the project's pyproject.toml / ruff.toml if present.
return {
  cmd = { 'ruff', 'server' },
  filetypes = { 'python' },
  root_markers = { 'pyproject.toml', 'ruff.toml', '.ruff.toml', '.git' },
  -- basedpyright owns hover; silence ruff's so K isn't answered by both.
  on_attach = function(client)
    client.server_capabilities.hoverProvider = false
  end,
}

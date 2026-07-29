-- Reference highlighting + navigation for the symbol under the cursor, in the
-- current file, via the LSP (textDocument/documentHighlight) -- semantic, so it
-- respects scope and shadowing. setup() highlights the occurrences on a short
-- debounce after the cursor settles and clears them on move; jump() powers the
-- ]r / [r motions that hop between those same occurrences. Not a plugin, just a
-- config module: wired up from init.lua.
local M = {}

-- Keep the highlight groups visible: github_dark defines LspReferenceRead/Write
-- but not Text (and clangd reports these as Text-kind); other schemes may
-- define none. Fall back sensibly. Re-run on ColorScheme -- a switch clears
-- these overrides.
local function ensure_hl()
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = 'LspReferenceRead' })) then
    vim.api.nvim_set_hl(0, 'LspReferenceRead', { link = 'Visual' })
    vim.api.nvim_set_hl(0, 'LspReferenceWrite', { link = 'Visual' })
  end
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = 'LspReferenceText' })) then
    vim.api.nvim_set_hl(0, 'LspReferenceText', { link = 'LspReferenceRead' })
  end
end

-- Jump to the next (forward=true) or previous use of the symbol under the
-- cursor, wrapping around. Issues a fresh documentHighlight and moves the
-- cursor directly -- no quickfix list involved.
function M.jump(forward)
  local bufnr = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({
    bufnr = bufnr,
    method = 'textDocument/documentHighlight',
  })[1]
  if not client then return end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request('textDocument/documentHighlight', params, function(err, result)
    if err or not result or #result < 2 then return end

    -- Convert every occurrence to buffer coordinates (row, byte col) so the
    -- cursor comparison is all in one unit; server ranges are in the client's
    -- offset encoding (utf-16 for clangd), the cursor position is in bytes.
    local occ = {}
    for _, dh in ipairs(result) do
      local s, e = dh.range.start, dh.range['end']
      local sline = vim.api.nvim_buf_get_lines(bufnr, s.line, s.line + 1, false)[1] or ''
      local eline = vim.api.nvim_buf_get_lines(bufnr, e.line, e.line + 1, false)[1] or ''
      occ[#occ + 1] = {
        srow = s.line,
        scol = vim.str_byteindex(sline, client.offset_encoding, s.character, false),
        erow = e.line,
        ecol = vim.str_byteindex(eline, client.offset_encoding, e.character, false),
      }
    end
    table.sort(occ, function(a, b)
      if a.srow ~= b.srow then return a.srow < b.srow end
      return a.scol < b.scol
    end)

    local cur = vim.api.nvim_win_get_cursor(0)
    local cl, cc = cur[1] - 1, cur[2]
    local function contains(o)
      local at_or_after_start = o.srow < cl or (o.srow == cl and o.scol <= cc)
      local before_end = cl < o.erow or (cl == o.erow and cc < o.ecol)
      return at_or_after_start and before_end
    end

    local n, target, idx = #occ, nil, nil
    for i, o in ipairs(occ) do
      if contains(o) then idx = i; break end
    end
    if idx then
      -- On an occurrence: step to the neighbour, wrapping around the ends.
      target = occ[forward and (idx % n) + 1 or ((idx - 2) % n) + 1]
    elseif forward then
      for _, o in ipairs(occ) do
        if o.srow > cl or (o.srow == cl and o.scol > cc) then target = o; break end
      end
      target = target or occ[1]
    else
      for i = n, 1, -1 do
        local o = occ[i]
        if o.srow < cl or (o.srow == cl and o.scol < cc) then target = o; break end
      end
      target = target or occ[n]
    end

    vim.api.nvim_win_set_cursor(0, { target.srow + 1, target.scol })
  end, bufnr)
end

-- Install the highlight-group fallback and the per-buffer highlight autocmds.
-- Called once from init.lua; the ]r / [r keymaps live there too.
function M.setup()
  ensure_hl()

  local group = vim.api.nvim_create_augroup('lsp-reference-highlight', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = ensure_hl })

  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or not client:supports_method('textDocument/documentHighlight') then
        return
      end
      local buf = args.buf
      -- Wire the buffer up only once, even if several clients attach.
      if vim.b[buf].ref_highlight then return end
      vim.b[buf].ref_highlight = true

      local timer
      vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'InsertEnter' }, {
        group = group,
        buffer = buf,
        callback = function()
          vim.lsp.buf.clear_references()
          if timer then timer:stop() end
          timer = vim.defer_fn(function()
            if vim.api.nvim_get_current_buf() == buf then
              vim.lsp.buf.document_highlight()
            end
          end, 200)
        end,
      })
      vim.api.nvim_create_autocmd('LspDetach', {
        group = group,
        buffer = buf,
        callback = function()
          if timer then timer:stop() end
          vim.lsp.buf.clear_references()
        end,
      })
    end,
  })
end

return M

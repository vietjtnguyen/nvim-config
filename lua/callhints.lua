-- Inline usage hints: virtual text at each symbol's declaration line showing
-- how much it's used, split into in-file vs out-of-file. Functions show their
-- callers (from the LSP call hierarchy); types, fields and enum values show
-- their references. Works for any server providing these (here, clangd). Not a
-- plugin, just a config module: toggle per buffer with :CallHints, refreshes
-- (debounced) on save.
local M = {}

local ns = vim.api.nvim_create_namespace('callhints')

-- SymbolKind values we annotate (see :help vim.lsp.protocol.SymbolKind),
-- grouped by how usage is counted. Callables use the call hierarchy (incoming
-- calls); everything else uses plain references.
local CALL_KINDS = {
  [6] = true, -- Method
  [9] = true, -- Constructor
  [12] = true, -- Function
}
local REF_KINDS = {
  [5] = true, -- Class
  [23] = true, -- Struct
  [10] = true, -- Enum
  [11] = true, -- Interface
  [8] = true, -- Field (member variable)
  [22] = true, -- EnumMember (enumerator)
}

-- 'call' -> count callers via call hierarchy; 'ref' -> count references;
-- nil -> don't annotate this kind.
local function strategy_for(kind)
  if CALL_KINDS[kind] then return 'call' end
  if REF_KINDS[kind] then return 'ref' end
  return nil
end

-- Per-buffer state: whether hints are on, a generation counter used to discard
-- results from a superseded refresh (a save mid-flight bumps it so the old
-- async callbacks no-op), and the debounce timer for save-triggered refreshes.
local state = {}

local function get_state(bufnr)
  if not state[bufnr] then
    state[bufnr] = { enabled = false, gen = 0, timer = nil }
  end
  return state[bufnr]
end

-- First attached client that can do the whole job: documentSymbol to find the
-- symbols, references for the non-callable ones, call hierarchy for callables.
local function get_client(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c:supports_method('textDocument/documentSymbol')
      and c:supports_method('textDocument/references')
      and c:supports_method('textDocument/prepareCallHierarchy') then
      return c
    end
  end
  return nil
end

-- Flatten a documentSymbol response into {line, position, strategy} for every
-- symbol we annotate. Handles both response shapes: hierarchical
-- DocumentSymbol[] (selectionRange + nested children, e.g. fields/methods
-- inside a class -- what clangd returns) and flat SymbolInformation[].
local function collect_symbols(symbols, out)
  for _, s in ipairs(symbols or {}) do
    if s.selectionRange then
      -- DocumentSymbol: selectionRange is the name itself, the right spot both
      -- to anchor the hint and to query from.
      local strategy = strategy_for(s.kind)
      if strategy then
        out[#out + 1] = {
          line = s.selectionRange.start.line,
          position = s.selectionRange.start,
          strategy = strategy,
        }
      end
      if s.children then
        collect_symbols(s.children, out)
      end
    elseif s.location then
      -- SymbolInformation: flat, no children, less precise position.
      local strategy = strategy_for(s.kind)
      if strategy then
        out[#out + 1] = {
          line = s.location.range.start.line,
          position = s.location.range.start,
          strategy = strategy,
        }
      end
    end
  end
  return out
end

local function set_hint(bufnr, line, chunks)
  vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
    virt_text = chunks,
    virt_text_pos = 'eol',
    hl_mode = 'combine',
  })
end

-- Draw one hint. The first chunk is an unhighlighted gap separating the chip
-- from the code; the second carries the CallHints background (the "chip"),
-- padded a space each side so it reads as a pill. `label` is "callers" for
-- functions, "refs" for everything else.
local function render(bufnr, line, label, in_file, out_file)
  local text
  if in_file == 0 and out_file == 0 then
    text = string.format(' %s: none ', label)
  else
    text = string.format(' %s: %d in-file, %d out ', label, in_file, out_file)
  end
  set_hint(bufnr, line, { { '  ' }, { text, 'CallHints' } })
end

-- Recompute and redraw all hints for a buffer. Fires one documentSymbol
-- request, then per symbol either a prepareCallHierarchy + incomingCalls chain
-- (callables) or a references request (everything else); each callback places
-- its own extmark as it lands, so hints fill in progressively.
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = get_state(bufnr)
  if not st.enabled then return end

  local client = get_client(bufnr)
  if not client then return end

  -- Bump the generation and clear now; any in-flight callback from a previous
  -- refresh will see the mismatch and drop its (now stale) result.
  st.gen = st.gen + 1
  local gen = st.gen
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local buf_uri = vim.uri_from_bufnr(bufnr)
  local buf_fname = vim.uri_to_fname(buf_uri)

  local function stale()
    return not vim.api.nvim_buf_is_valid(bufnr) or get_state(bufnr).gen ~= gen
  end

  -- Compare resolved file paths, not raw URIs, so percent-encoding differences
  -- between the server's URIs and ours don't put a hit in the wrong bucket.
  local function in_this_file(uri)
    return uri ~= nil and vim.uri_to_fname(uri) == buf_fname
  end

  -- Callables: distinct incoming callers, split in-file vs out-of-file.
  local function count_callers(sym)
    client:request('textDocument/prepareCallHierarchy', {
      textDocument = { uri = buf_uri },
      position = sym.position,
    }, function(e1, items)
      if e1 or stale() or not items or not items[1] then return end
      client:request('callHierarchy/incomingCalls', {
        item = items[1],
      }, function(e2, calls)
        if e2 or stale() then return end
        local in_file, out_file = 0, 0
        for _, call in ipairs(calls or {}) do
          if call.from and in_this_file(call.from.uri) then
            in_file = in_file + 1
          else
            out_file = out_file + 1
          end
        end
        render(bufnr, sym.line, 'callers', in_file, out_file)
      end, bufnr)
    end, bufnr)
  end

  -- Everything else: reference locations, split in-file vs out-of-file. Exclude
  -- the declaration itself so it doesn't inflate the count.
  local function count_refs(sym)
    client:request('textDocument/references', {
      textDocument = { uri = buf_uri },
      position = sym.position,
      context = { includeDeclaration = false },
    }, function(e1, locs)
      if e1 or stale() then return end
      local in_file, out_file = 0, 0
      for _, loc in ipairs(locs or {}) do
        if in_this_file(loc.uri or loc.targetUri) then
          in_file = in_file + 1
        else
          out_file = out_file + 1
        end
      end
      render(bufnr, sym.line, 'refs', in_file, out_file)
    end, bufnr)
  end

  client:request('textDocument/documentSymbol', {
    textDocument = { uri = buf_uri },
  }, function(err, result)
    if err or stale() then return end
    for _, sym in ipairs(collect_symbols(result, {})) do
      if sym.strategy == 'call' then
        count_callers(sym)
      else
        count_refs(sym)
      end
    end
  end, bufnr)
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  get_state(bufnr).enabled = true
  M.refresh(bufnr)
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local st = get_state(bufnr)
  st.enabled = false
  st.gen = st.gen + 1 -- invalidate any in-flight callbacks
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if get_state(bufnr).enabled then
    M.disable(bufnr)
  else
    M.enable(bufnr)
  end
end

-- Register the :CallHints command and the save-refresh autocmd. Called once
-- from init.lua.
function M.setup()
  vim.api.nvim_create_user_command('CallHints', function()
    M.toggle()
  end, { desc = 'Toggle caller/reference-count hints for the buffer' })

  local group = vim.api.nvim_create_augroup('callhints', { clear = true })

  -- Chip styling: Pmenu background (tooltip feel) + Comment foreground so
  -- the text is dimmer than menu text. A colorscheme switch clears custom
  -- highlight groups, so recompute and re-apply on ColorScheme.
  local function apply_hl()
    local pmenu = vim.api.nvim_get_hl(0, { name = 'Pmenu', link = false })
    local comment = vim.api.nvim_get_hl(0, { name = 'Comment', link = false })
    vim.api.nvim_set_hl(0, 'CallHints', { bg = pmenu.bg, fg = comment.fg })
  end
  apply_hl()
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = apply_hl })

  -- Refresh on save, debounced: an in-flight refresh's callbacks are already
  -- invalidated by the generation bump, so back-to-back saves stay cheap.
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(args)
      local st = get_state(args.buf)
      if not st.enabled then return end
      if st.timer then st.timer:stop() end
      st.timer = vim.defer_fn(function() M.refresh(args.buf) end, 300)
    end,
  })
  -- Don't let the state table grow unbounded as buffers come and go.
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(args) state[args.buf] = nil end,
  })
end

return M

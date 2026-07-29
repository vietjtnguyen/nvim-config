-- blink.cmp source: evaluate the math expression before the cursor with
-- Python (math.* imported unqualified) and offer the result as a completion.
--- @module 'blink.cmp'
--- @class blink.cmp.Source
local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
  return { '+', '-', '*', '/', '(', ')', '.', ',', '%' }
end

function source:get_completions(ctx, callback)
  local before_cursor = ctx.line:sub(1, ctx.cursor[2])
  local expr = before_cursor:match('([%w%.%+%-%*/%(%)%%,%s]+)$')

  -- Require at least one digit so plain identifiers (e.g. mid-typing a
  -- variable name) don't get shelled out to Python on every keystroke.
  if not expr or not expr:match('%d') then
    callback({ items = {}, is_incomplete_forward = true, is_incomplete_backward = true })
    return function() end
  end

  local done = false
  local proc = vim.system(
    { 'python3', '-c', 'from math import *\nprint(' .. expr .. ')' },
    { text = true },
    function(result)
      if done then return end
      vim.schedule(function()
        local items = {}
        if result.code == 0 and result.stdout and vim.trim(result.stdout) ~= '' then
          local value = vim.trim(result.stdout)
          local start_col = ctx.cursor[2] - #expr
          table.insert(items, {
            label = vim.trim(expr) .. ' = ' .. value,
            kind = require('blink.cmp.types').CompletionItemKind.Value,
            textEdit = {
              newText = value,
              range = {
                start = { line = ctx.cursor[1] - 1, character = start_col },
                ['end'] = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] },
              },
            },
          })
        end
        callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
      end)
    end
  )

  return function()
    done = true
    proc:kill(9)
  end
end

return source

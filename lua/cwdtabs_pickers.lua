-- Telescope pickers over the cwdtabs model. Kept out of the cwdtabs core, which
-- stays finder-agnostic; this is the config-level Telescope view of it, built
-- on the public require('cwdtabs').groups() data.

local cwdtabs = require('cwdtabs')
local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

local M = {}

local function goto_tab(id)
  if id and vim.api.nvim_tabpage_is_valid(id) then
    vim.api.nvim_set_current_tabpage(id)
  end
end

-- Run a picker whose entries each carry a `.tab` id to switch to on <CR>.
local function run(title, entries, opts)
  opts = opts or {}
  pickers.new(opts, {
    prompt_title = title,
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e)
        return { value = e, display = e.display, ordinal = e.ordinal }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(bufnr)
        if entry then goto_tab(entry.value.tab) end
      end)
      return true
    end,
  }):find()
end

-- Pick any tab across all groups. A '●' marks the current tab.
function M.pick_tabs(opts)
  local entries = {}
  for _, g in ipairs(cwdtabs.groups()) do
    for _, t in ipairs(g.tabs) do
      entries[#entries + 1] = {
        tab = t.id,
        display = string.format('%s %s › %s',
          t.is_current and '●' or ' ', g.label, t.label),
        ordinal = g.label .. ' ' .. t.label,
      }
    end
  end
  run('Tabs', entries, opts)
end

-- Pick a CWD group; opens its first tab. A '●' marks the current group.
function M.pick_groups(opts)
  local entries = {}
  for _, g in ipairs(cwdtabs.groups()) do
    entries[#entries + 1] = {
      tab = g.tabs[1].id,
      display = string.format('%s %-16s (%d)  %s',
        g.has_current and '●' or ' ', g.label, #g.tabs,
        vim.fn.fnamemodify(g.cwd, ':~')),
      ordinal = g.label .. ' ' .. g.cwd,
    }
  end
  run('Tab groups (CWD)', entries, opts)
end

return M

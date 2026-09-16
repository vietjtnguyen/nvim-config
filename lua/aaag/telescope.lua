-- aaag telescope picker: the find-and-jump complement to the float dashboard.
-- A picker is line-oriented, so the list shows one line per session (glyph,
-- name, status, age) and the multi-line card lives in the preview pane. Selecting
-- an entry jumps to its terminal tab -- same action as <CR> in the dashboard.
--
-- Loaded lazily and degrades gracefully: if telescope isn't installed, we say so
-- rather than erroring.

local jump = require('aaag.jump')

local M = {}

function M.picker(cards, card_text)
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    vim.notify('aaag: telescope.nvim is not installed', vim.log.levels.WARN)
    return
  end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local previewers = require('telescope.previewers')
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = 'Claude sessions',
    finder = finders.new_table({
      results = cards,
      entry_maker = function(card)
        local line = string.format('%s  [%s]  %s  %s',
          card.name, card.attention or '?',
          card.last_ago and ('last ' .. card.last_ago) or '',
          card.cwd)
        return {
          value = card,
          display = line,
          ordinal = card.name .. ' ' .. card.cwd,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = 'Session',
      define_preview = function(self, entry)
        vim.api.nvim_buf_set_lines(
          self.state.bufnr, 0, -1, false, card_text(entry.value))
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry and not jump.to_pid(entry.value.pid) then
          vim.notify('aaag: ' .. entry.value.name ..
            ' is not in a visible nvim terminal (tmux/external?)',
            vim.log.levels.WARN)
        end
      end)
      return true
    end,
  }):find()
end

return M

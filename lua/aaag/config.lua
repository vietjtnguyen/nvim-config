-- aaag configuration: a single mutable options table, seeded by defaults and
-- overwritten once by setup(). Kept in its own module so every other module can
-- read the live config without a require cycle back through init.

local M = {}

M.defaults = {
  -- Install the default <leader>-style keymaps (see init.set_default_keymaps).
  default_keymaps = false,

  -- Show a one-line keymap cheat-sheet at the top of the dashboard float.
  show_help = false,

  -- Initial fold state when the dashboard opens:
  --   'expanded'  every card shows all fields
  --   'collapsed' every card shows only its one-line header
  --   'blocked'   collapse all except cards waiting on you (attention='blocked')
  fold_default = 'expanded',

  -- Where Claude Code keeps its state. Sessions live under <dir>/sessions and
  -- transcripts under <dir>/projects; overridable for non-standard installs.
  claude_dir = vim.fn.expand('~/.claude'),

  -- Model for the summary calls. Haiku is the cheapest/fastest tier; there is
  -- nothing below it, and latency here is dominated by context prefill, not
  -- model size, so a "simpler" model buys nothing (measured).
  model = 'claude-haiku-4-5-20251001',

  -- A live session with no transcript activity for this many days is marked
  -- stale (it's still running, just untouched).
  stale_days = 3,

  -- The dashboard can show dormant (not-live) conversations below the live ones,
  -- but hides them by default -- <Tab> reveals/hides the section. When shown,
  -- their initial fold state is `dormant_fold_default` ('expanded'|'collapsed').
  show_dormant = false,
  dormant_fold_default = 'collapsed',

  -- Dashboard float geometry (fraction of the editor) and grid layout. Columns
  -- 'auto' picks a count from the available width and `card_width` (the target
  -- minimum cell width), capped at `max_columns`; set a number to force it.
  width_frac = 0.92,
  height_frac = 0.88,
  columns = 'auto',
  max_columns = 3,
  card_width = 46,
  col_sep = 3,
  -- Draw a light vertical rule between grid columns (a "│" in the gap). Set
  -- false for plain whitespace between columns.
  column_rule = true,

  -- Bound on the transcript tail fed to the stateless (B) summary call: keep the
  -- most recent user/assistant turns, up to tail_msgs turns or tail_chars
  -- characters, whichever limit is reached first.
  tail_msgs = 50,
  tail_chars = 35000,
}

-- The live options, replaced wholesale by setup(). Starts as the defaults so the
-- module is usable (e.g. in tests) before setup() runs.
M.opts = vim.deepcopy(M.defaults)

function M.set(opts)
  M.opts = vim.tbl_extend('force', vim.deepcopy(M.defaults), opts or {})
  return M.opts
end

return M

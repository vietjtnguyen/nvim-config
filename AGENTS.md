How I like to work on this config. It stays high-level on purpose: the config
documents its own details, so this file is about judgment, not inventory (if it
parroted the setup it'd just drift out of sync).

## How I like to work

- **Diagnose and discuss before implementing.** For anything non-trivial, frame
  the problem and the options with their tradeoffs, and get a decision before
  writing code. A question is a question, not a request to build the feature.
  Recommend a direction — don't just survey, and don't jump ahead.
- **Verify against the real thing, not docs or assumptions.** "It should work"
  isn't done; "I ran it, here's the output" is. Prove changes against the actual
  editor / LSP / toolchain before claiming success.
- **Minimal and legible over clever or heavy.** Hand-roll when it's close;
  reach for a plugin when it clearly earns its place. Survey the landscape
  before adopting something new. Not dogmatic — just deliberate.
- **Atomic commits, and I do the committing.** Present the diff and let me
  review; commit when I say so. Pin dependencies to exact versions, and don't
  commit what can be regenerated.
- **Tell me the truth** — failures, uncertainty, and fragility you notice in
  passing — over a tidy-looking result that's secretly brittle.
- **Don't hoard trivia.** If the code or git history already says it, it doesn't
  need restating.

## Orientation (just enough)

Robotics/ROS C++ and Python, a lot of it built inside containers. The config is
a single `init.lua` plus `lua/` modules, using Neovim's built-in plugin manager
and native LSP. Read it rather than trusting a summary — including this one.

## When in doubt

- Offer options with a recommendation and the reasoning; let me choose.
- Change what you were asked to; flag adjacent problems rather than silently
  fixing them.
- When work spans this repo and external/infra files, commit only this repo and
  call out the rest as mine to handle.
- Testing the config headlessly? Neovim won't load `init.lua` on its own under
  `-l` — that's a footgun, not a config detail.

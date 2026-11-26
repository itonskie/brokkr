## Delegation to the local model (brokkr)

Claude usage is the scarce resource. Every Claude turn re-reads the whole session, so the local model does the bulk work and Claude takes few, short turns.

**Send to the local model (brokkr MCP tools, no Claude usage):**
- **Reading code.** Before you read more than two or three files to understand something, call `local_ask` and work from its answer. Open a file yourself only to check a specific line it cites.
- **One implementation item.** Call `local_task` with 3-6 lines (goal, files, a pattern to copy) and an exact `check` command. Review with `git diff`, then call `local_accept`, `local_retry` (precise feedback) or `local_drop`.
- **A whole phase of a task list.** Run it in the background with Bash, and do not poll:
  `forge.sh batch TASKS.md <phase> --effort medium` (forge.sh is in the brokkr plugin: `skills/delegate/scripts/forge.sh`).
  Failed checks go back to the worker automatically (up to 3 times). Passing items are committed one by one. When it ends, read only the review packet `.brokkr/batch-*.md`, and open a diff only for items with a FLAG or a FAIL.

**Keep for Claude:**
- Planning, specs, data formats and other design choices; security code.
- Web research (the local model has no web search).
- The check of scan and image drafts. The local model can see images and reads labels, wire colours and pin numbers well, but it guesses part names. Let the worker read the crop (plus the legend) and write the draft; then examine the same crop one time and correct it. Do not write the data yourself.
- Items that failed locally 3 times, and changes of a few lines that are faster to write than to describe.
- The review of each batch packet.

**Session rules:**
- One phase or one design job per session. Then write a checkpoint and end the session.
- Do not switch models in a session; a switch re-reads the whole history at full price. Use Sonnet by default; start a separate session on Opus for planning or hard problems.
- Avoid pauses over one hour in a session; the cache expires and the next turn re-reads everything.
- Run `local_report` at the end of a phase to see usage spent against usage saved.

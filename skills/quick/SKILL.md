---
name: quick
description: Fast path for small jobs on the local-model worker. Takes one short task as text, or a simple markdown task list (checkbox items), sends each item to the Qwen worker on Strata, checks the result, and lands it - with no long task file. Use when the user says "/brokkr:quick", "quick task", "run this task list", "let the worker do these", or gives a short job for the local model. For big or unclear work use brokkr:delegate instead.
---

# Quick

Same worker and safety as `brokkr:delegate` (own worktree, no git rights), with less ceremony. The runner is `../delegate/scripts/forge.sh` relative to this skill's directory.

## Input

Either a task as plain text, or the path to a task list like this:

```markdown
# <What we build>
Check: `<command that must pass after every item>`

- [ ] <item 1, one sentence>
- [ ] <item 2> (check: `<command for this item only>`)
- [x] <done items are skipped>
```

The file needs only the checkbox lines. `Check:` is optional. An item that starts with `**Claude:**` is yours: do it yourself in the main session (design, reading scans or images, research, choices with the user), then commit and tick it. Never send it to the worker. If there is no check, choose one yourself from the project (its test command, or a run of the program).

## Before the first item

Run `forge.sh begin`. It marks the start, so the usage report can count your own tokens per item.

If the user wants a real comparison, add `--compare opus` (or `sonnet`) to the run command. The same task then also runs once on that Anthropic model in a throwaway worktree. That run uses the user's plan, so do it only when asked, or on a few sample items.

## For each open item, in order

1. **Write the worker text.** Expand the item into 3-6 lines: the goal, the files to read or change, and the check command. Add a code pattern to copy if one exists. Do not write a full delegate task file.
2. **Pick the effort.** `low` for mechanical items, `medium` by default, `high` for logic with edge cases.
3. **Run it:**
   ```bash
   forge.sh quick "<worker text>" --effort <level> --check "<check command>"
   ```
   The script prints the worker name, the summary and `check: PASS` or `check: FAIL`.
4. **Review fast.** Read `git diff <base> brokkr/<name>`. Look for changes outside the item, weakened tests and stub code.
5. **Land it.**
   - PASS and a clean diff: run `forge.sh accept <name>`, then commit with message `brokkr: <item>`. The commit lets the next item build on this one.
   - FAIL or a bad diff: run `forge.sh retry <name> <feedback file>` once, with short exact feedback. If it fails again, fix it yourself in the worktree, then accept. Note the takeover.
6. **Tick the item** (`- [x]`) in the list file.

Run the items one at a time. Strata serves one request at a time, and each item builds on the commit before it.

Before the first commit, tell the user once that each item lands as its own commit on the current branch. If the user is on `main` of a shared repo, ask first.

## End

Give one short table: item, effort, attempts, result (worker / retried / taken over). Then list anything the user must check by hand.

Then run `forge.sh report` and give its totals: the Anthropic usage spent (your own tokens), the usage the worker saved, and the net. If any item had an A/B run, lead with those real numbers.

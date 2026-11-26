---
name: delegate
description: Hand a well-defined coding task to a local-model worker (a headless claude -p running on Qwen behind Strata on the home server) and review its result. The main session stays the orchestrator - it reads, plans, writes the task, and checks the work; the local worker writes the code in its own git worktree. Use when the user says "delegate", "send it to the worker", "let the local model do it", "brokkr", or asks to outsource implementation work to the local LLM.
---

# Delegate

Two roles:

- **You (main session, Anthropic model):** read the code, decide what to build, write the task, review the result, decide to accept, retry or take over. You own quality.
- **Worker (local model):** a headless `claude -p` on Qwen through Strata. It edits files and runs commands in its own git worktree on branch `brokkr/<name>`. It cannot commit, push, merge or switch branches.

The runner is `scripts/forge.sh` in this skill's directory. Run it from the target repository.

## 1. Decide if the task fits

Good worker tasks:
- One clear change with a known shape: a function, a test file, a migration, an endpoint that copies an existing one.
- Mechanical edits across files that follow a pattern you can show.
- Boilerplate, fixtures, docs from code.

Keep these yourself:
- Design choices, unclear requirements, security code, tricky concurrency.
- Work that needs web access (the worker has no WebFetch or WebSearch).
- Anything faster to write than to specify.

Split big work into tasks of about 1-5 files each. The worker writes at most 4096 output tokens per turn, so one huge file in one write fails.

## 2. Write the task file

Write it to `.brokkr/tasks/<name>.md`. `<name>` is lowercase, digits and `-`. The worker sees only this file and the repo, so be concrete:

```markdown
## Goal
<one or two sentences: what must be true when done>

## Read first
- path/to/file.py — <why>
- path/to/example.py — copy this pattern

## Do
1. <step>
2. <step>

## Do not
- <files or behaviour to leave alone>

## Checks
- `<exact command>` — must pass
```

Rules for the task:
- Give exact file paths and exact check commands. The worker must not guess how to run tests.
- Show an example to copy when one exists. Local models follow examples far better than prose.
- Make the checks runnable in a fresh worktree. A worktree has no `node_modules`, `.venv` or other ignored files. If the checks need them, pass `--setup` (step 4).

## 3. Pick the thinking level

Choose `--effort` from the task, not by habit. Higher levels think longer, so each turn is slower.

| Level | Use for |
|---|---|
| `low` | Mechanical work with a clear example to copy: renames, boilerplate, fixtures, docs from code, a small edit at a known place. |
| `medium` (default) | One clear change with an example, ordinary functions and their tests. |
| `high` | Logic with edge cases, parsing, algorithms, state, a fix for a failing test, or a change across several files with no example to copy. |

On a retry:
- Raise the level when the worker made a reasoning mistake (wrong logic, missed edge case).
- Keep the level when the mistake was in the task file (missing path, wrong check command). Fix the task text instead.

`high` maps to Qwen's highest level (xhigh). Thinking cannot be fully off through Claude Code.

## 4. Run the worker

Run it in the background so you can keep working:

```bash
<skill-dir>/scripts/forge.sh run <name> .brokkr/tasks/<name>.md [--effort low|medium|high] [--base <ref>] [--setup "<cmd>"]
```

- `--base` sets the commit to branch from (default `HEAD`). Commit or stash your own changes first if the worker needs them.
- `--setup` runs a command in the worktree before the worker starts, for example `npm ci` or `uv sync`.
- If Strata does not answer, the script runs `BROKKR_GPU_CMD` to load the chat model on the server.
- Strata serves one request at a time. Run one worker at a time. Queue the next task after the first ends.

The script prints a summary when the attempt ends: result, turns, the report path, and the diff command.

## 5. Review the work

Never trust the worker's report alone. For each attempt:

1. Read the report: `.brokkr/runs/<name>/attempt-N.report.md`.
2. Read the full diff: `git diff <base> brokkr/<name>`.
3. Run the checks yourself in the worktree: `cd .brokkr/wt/<name> && <check command>`.
4. Look for what local models often get wrong:
   - Changes outside the task, or deleted code it did not understand.
   - Tests that pass because they test nothing, or were weakened to pass.
   - Stub or placeholder code, `TODO`, swallowed errors.
   - Invented functions, imports or APIs.

If the result is `error_max_turns`, `timeout` or an API error, read the end of `attempt-N.jsonl` to see where it got stuck.

## 6. Decide

- **Accept:** `forge.sh accept <name>`. The work lands staged (not committed) on your current branch, and the worktree is removed. Review the staged diff once more, then commit.
- **Retry:** write precise feedback to `.brokkr/tasks/<name>.feedback-N.md` (what is wrong, where, what to do instead), then run `forge.sh retry <name> <file> [--effort <level>]`. The worker resumes its own session, so it keeps its context. Allow at most 2 retries.
- **Take over:** if two retries fail, or the fix is small, do it yourself in the worktree or in your branch. Then `forge.sh accept` or `forge.sh drop`.
- **Drop:** `forge.sh drop <name>` deletes the worktree, branch and run files.

Tell the user what the worker did, what you changed, and what checks passed.

## MCP tools and batch mode

The plugin also starts the `brokkr` MCP server. Its tools wrap the same commands: `local_ask` (read-only question about the repo), `local_task`, `local_retry`, `local_accept`, `local_drop`, `local_report`. Prefer them to Bash calls of `forge.sh`.

For a whole phase of a task list, run `forge.sh batch <TASKS.md> <phase>` in the background. It sends failed checks back to the worker (up to 3 times), commits each passing item, and writes a review packet to `.brokkr/batch-*.md`. Read the packet, not full diffs. The rules for when to delegate are in the plugin's `DELEGATION.md`; copy them into a project's `CLAUDE.md`.

## Other commands

- `forge.sh status` lists workers. `forge.sh status <name>` shows the last attempt.
- `forge.sh begin` marks the start of your work on a task. `forge.sh report` then shows, per item, the usage you spent (from this session's transcript), the usage the worker saved, and the net.
- `run --compare opus|sonnet` also runs the task once on that Anthropic model in a throwaway worktree, for a real A/B. It uses the user's plan; run it only when asked.

## Settings

Configure it with environment variables: `BROKKR_URL`, `BROKKR_MODEL`, `BROKKR_KEY` or `BROKKR_KEY_CMD`, `BROKKR_GPU_CMD` (empty skips the model load), `BROKKR_TIMEOUT` (seconds, default 1800), `BROKKR_MAX_TURNS` (default 80). The API key is read for each run and is never written to disk.

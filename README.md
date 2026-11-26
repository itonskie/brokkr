# brokkr

A Claude Code plugin that sends heavy code generation to a model on your own hardware.

Claude plans the work and reviews it. A headless worker (`claude -p` pointed at a local model) writes the code in its own git worktree. Paid Claude tokens go to planning and review. The local GPU does the typing.

```
Claude Code (plans, reviews)
   │  local_task / local_ask         (MCP tools)
   ▼
brokkr ── git worktree brokkr/<name> ── claude -p ──▶ Strata (local model, OpenAI/Anthropic API)
   │                                                      │
   │◀──────────── diff + check result ───────────────────┘
   ▼
local_accept │ local_retry │ local_drop
```

## What it does

- **`local_ask`**: the local model reads the repo and answers a question. Claude works from the answer and does not read the files itself.
- **`local_task`**: the local model implements one item in a separate worktree. A `check` command (tests, build) decides pass or fail. Claude reviews the diff, then accepts, retries with feedback, or drops it.
- **Batch mode**: `forge.sh batch TASKS.md <phase>` runs every open item of a phase. Failed checks go back to the worker up to 3 times (a local fix loop). Passing items are committed one by one. A review packet lists only the items that need a look.
- **Usage report**: `local_report` (or `forge.sh report`) shows tokens spent by Claude against tokens done locally, priced at Anthropic API rates. `--compare opus` runs the same task on Anthropic for a real A/B.
- **Model load**: if the inference server does not answer, brokkr can run a command that loads the chat model on the server.

The worker cannot commit, push, switch branches or use `gh`. Git history belongs to the main session.

## Results so far

Two personal projects, 40+ delegated tasks (from `.brokkr/ledger.jsonl`):

| | Tokens done locally | Output tokens | Same tokens at Opus API rates |
|---|---|---|---|
| Project A | 21.1 M | 0.27 M | about $35 |
| Project B | 94.5 M | 1.09 M | about $49 |

Most of the token count is cached context that the worker re-reads on each turn. These runs did not record the orchestrator side, so the dollar figures are gross, not net.

## Hardware

- Minisforum UM890 mini PC, 64 GB RAM
- RTX 5060 Ti 16 GB as an eGPU (moving to an RTX 3090 24 GB)
- [Strata](https://github.com/Niko1221/Strata), an open-source MoE inference engine, serving a quantized Qwen model

Any server that speaks the Anthropic Messages API should work.

## Install

```
/plugin marketplace add itonskie/brokkr
/plugin install brokkr@brokkr
```

Requirements: Claude Code, `git`, `python3`, `curl`, and an inference server.

## Settings

Set these as environment variables:

| Variable | Use | Default |
|---|---|---|
| `BROKKR_URL` | server address, no `/v1` | `http://localhost:8090` |
| `BROKKR_MODEL` | model name the server reports | `qwen3.8-flash-next-iq3_xxs` |
| `BROKKR_KEY` | API key | (none) |
| `BROKKR_KEY_CMD` | command that prints the key, if `BROKKR_KEY` is not set | (none) |
| `BROKKR_GPU_CMD` | command that loads the chat model on the server | (none: skip) |
| `BROKKR_TIMEOUT` | seconds per attempt | `1800` |
| `BROKKR_MAX_TURNS` | worker turn limit per attempt | `80` |

The key is read for each run and is never written to disk.

## When to delegate

See [DELEGATION.md](DELEGATION.md). In short: send code reading and well-defined implementation items to the local model. Keep planning, design choices, security code and web research for Claude.

## License

MIT

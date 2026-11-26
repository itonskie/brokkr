#!/usr/bin/env bash
# forge.sh — run a local-model worker (headless claude -p on Strata) in its own
# git worktree. The main Claude Code session writes the task, runs this, and
# reviews the result. The worker never commits; this script snapshots its work
# as a commit on brokkr/<name> after each attempt so the diff is easy to read.
#
#   forge.sh run    <name> <task.md> [--effort LEVEL] [--base REF] [--setup CMD] [--check CMD]
#   forge.sh quick  "<task text>" [same options as run]   name and task file are made for you
#   forge.sh retry  <name> <feedback.md> [--effort LEVEL]
#   forge.sh status <name>
#   forge.sh accept <name>      squash the work into the current branch (staged, not committed)
#   forge.sh drop   <name>      delete the worktree, branch and run files
#   forge.sh begin              mark the start of orchestrator work (for the token report)
#   forge.sh ask    "<question>" [--effort LEVEL]   read-only answer about the repo from the local model
#   forge.sh batch  <TASKS.md> <phase> [--effort LEVEL] [--retries N] [--setup CMD]
#                               run every open worker item of a phase; failed checks go back to
#                               the worker (local fix loop); passing items are committed; writes a
#                               review packet to .brokkr/batch-*.md
#   forge.sh report             tokens and Anthropic-price comparison from .brokkr/ledger.jsonl
#
# run/quick --compare MODEL also runs the same task once on an Anthropic model
# (for example opus or sonnet) in a throwaway worktree, for a real A/B. That run
# uses your Anthropic plan or API credit.
#
# Settings (environment variables):
#   BROKKR_URL        Strata address, no /v1        (default http://localhost:8090)
#   BROKKR_MODEL      model name Strata reports     (default qwen3.8-flash-next-iq3_xxs)
#   BROKKR_KEY        API key; if unset it is read with BROKKR_KEY_CMD (never written to disk)
#   BROKKR_KEY_CMD    command that prints the key
#   BROKKR_GPU_CMD    command that loads the chat model on the server (empty = skip)
#   BROKKR_TIMEOUT    seconds of runtime per attempt (default 1800)
#   BROKKR_MAX_TURNS  worker turn limit per attempt (default 80)
#   BROKKR_GIT_NAME / BROKKR_GIT_EMAIL  commit identity for batch commits when git has none
#
# --effort is the worker's thinking level: low, medium (default) or high.
# Strata maps high to Qwen's xhigh. A retry keeps the level of the last attempt
# unless --effort is given again.
set -euo pipefail

URL="${BROKKR_URL:-http://localhost:8090}"
MODEL="${BROKKR_MODEL:-qwen3.8-flash-next-iq3_xxs}"
KEY_CMD="${BROKKR_KEY_CMD:-}"
GPU_CMD="${BROKKR_GPU_CMD:-}"
TIMEOUT="${BROKKR_TIMEOUT:-1800}"
MAX_TURNS="${BROKKR_MAX_TURNS:-80}"

# The worker may edit files and run commands, but git history and branches
# belong to the main session. Deny beats allow, so Bash stays broadly allowed.
# No WebFetch/WebSearch: they are server-side tools Strata does not have.
ALLOW_TOOLS="Read,Write,Edit,Glob,Grep,Bash,TodoWrite"
DENY_TOOLS="Bash(git commit:*),Bash(git push:*),Bash(git checkout:*),Bash(git switch:*),Bash(git worktree:*),Bash(git branch:*),Bash(git merge:*),Bash(git rebase:*),Bash(git reset:*),Bash(git stash:*),Bash(gh:*),Bash(sudo:*),Bash(rm -rf:*)"

die() { echo "brokkr: $*" >&2; exit 1; }

check_effort() {
  case "${1:-}" in low|medium|high) ;; *) die "effort must be low, medium or high (got '${1:-}')" ;; esac
}

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
STATE="$ROOT/.brokkr"
LEDGER="$STATE/ledger.jsonl"
HERE="$(cd "$(dirname "$0")" && pwd)"

ledger() { mkdir -p "$STATE"; python3 "$HERE/ledger.py" "$1" "$LEDGER" "${@:2}"; }

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

check_name() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "name must be lowercase letters, digits, . _ - (got '${1:-}')"
}

# Bash 3.2 (macOS) has no `timeout`. TERM, then KILL. Returns 124 on timeout.
run_bounded() {
  local secs="$1"; shift
  ( "$@" ) &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5; waited=$((waited+5))
    if (( waited >= secs )); then
      kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
  done
  wait "$pid"
}

# Any HTTP answer (401 without a key is fine) means Strata is up.
strata_up() {
  local code
  code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$URL/v1/models" || true)"
  [[ "$code" != "000" ]]
}

ensure_strata() {
  strata_up && return 0
  [[ -n "$GPU_CMD" ]] || die "Strata does not answer at $URL and BROKKR_GPU_CMD is empty"
  echo "brokkr: Strata is down; loading the chat model on the server…"
  eval "$GPU_CMD" >/dev/null || die "the model load command failed"
  local i
  for i in $(seq 60); do strata_up && return 0; sleep 5; done
  die "Strata still does not answer at $URL after the model load"
}

get_key() {
  if [[ -n "${BROKKR_KEY:-}" ]]; then printf '%s' "$BROKKR_KEY"; return; fi
  local k; k="$(eval "$KEY_CMD")" || true
  [[ -n "$k" ]] || die "no Strata API key: set BROKKR_KEY or BROKKR_KEY_CMD"
  printf '%s' "$k"
}

# Worker environment: only this process talks to Strata. The main session is
# not affected. No Anthropic login is used.
worker_claude() {
  local key="$1"; shift
  env -u ANTHROPIC_API_KEY \
    ANTHROPIC_BASE_URL="$URL" ANTHROPIC_AUTH_TOKEN="$key" \
    ANTHROPIC_MODEL="$MODEL" ANTHROPIC_SMALL_FAST_MODEL="$MODEL" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL" ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL" ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144 CLAUDE_CODE_MAX_OUTPUT_TOKENS=4096 \
    claude --permission-mode acceptEdits --strict-mcp-config \
      --allowedTools "$ALLOW_TOOLS" --disallowedTools "$DENY_TOOLS" \
      --max-turns "$MAX_TURNS" --output-format stream-json --verbose "$@"
}

PREAMBLE='You are a worker. A senior engineer wrote the task below and will review every line you change.

Rules:
- Do exactly the task. Do not change files or behaviour the task does not ask for.
- Stay inside the current directory.
- Do not commit, push, switch branches or touch git history. The reviewer handles git.
- Do not install packages or tools unless the task says so. If a check command cannot run, stop and say why in your report. Do not search for workarounds.
- When you finish, run the check commands from the task.
- End with this report and nothing after it:

REPORT
Status: done | partial | blocked
Changed files: <list>
Checks: <command> -> <pass/fail and a short reason>
Notes: <anything the reviewer must know, or "none">

TASK
'

# Run one attempt, then snapshot the worktree as a commit and print a summary.
attempt() {
  local name="$1" n="$2"; shift 2
  local run="$STATE/runs/$name" wt="$STATE/wt/$name"
  local out="$run/attempt-$n.jsonl" rc=0 start end effort
  effort="$(cat "$run/effort")"
  local key; key="$(get_key)"
  start=$(date +%s)
  ( cd "$wt" && run_bounded "$TIMEOUT" worker_claude "$key" --effort "$effort" "$@" ) > "$out" 2> "$run/attempt-$n.err" || rc=$?
  end=$(date +%s)
  echo "$n" > "$run/attempts"

  python3 - "$out" "$run/attempt-$n.report.md" "$rc" > "$run/attempt-$n.summary" <<'PY'
import json, sys
out, report, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
res = None
for line in open(out, errors="replace"):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") == "result":
        res = d
if res is None:
    status = "timeout" if rc == 124 else f"no-result (exit {rc})"
    text, turns = "", "?"
else:
    status = res.get("subtype", "?")
    if res.get("is_error"):
        status += f" (error: {res.get('api_error_status') or res.get('terminal_reason') or 'unknown'})"
    text, turns = res.get("result") or "", res.get("num_turns", "?")
open(report, "w").write(text)
print(f"result: {status}\nturns: {turns}")
PY

  git -C "$wt" add -A
  if git -C "$wt" diff --cached --quiet; then
    echo "changes: none in this attempt" >> "$run/attempt-$n.summary"
  else
    git -C "$wt" -c user.name=brokkr -c user.email=brokkr@localhost \
      commit -q --no-verify -m "brokkr: $name attempt $n"
  fi

  local base; base="$(cat "$run/base")"
  echo "brokkr: $name attempt $n finished in $(( (end-start)/60 ))m$(( (end-start)%60 ))s (effort $effort)"
  sed 's/^/  /' "$run/attempt-$n.summary"
  echo "  report: $run/attempt-$n.report.md"
  echo "  diff:   git diff $base brokkr/$name   ($(git diff --shortstat "$base" "brokkr/$name" | sed 's/^ *//'))"
  echo "  log:    $out"
  ledger worker "$name" "$n" "$out" "$effort" "$start" "$end"

  # The reviewer's own check, run by this script, not the worker's claim.
  if [[ -f "$run/check" ]]; then
    if ( cd "$wt" && bash -c "$(cat "$run/check")" ) > "$run/attempt-$n.check.log" 2>&1; then
      echo "  check:  PASS  ($(cat "$run/check"))"; echo pass > "$run/check.status"
    else
      echo "  check:  FAIL  ($(cat "$run/check")) -> $run/attempt-$n.check.log"; echo fail > "$run/check.status"
    fi
  fi
}

cmd_run() {
  local name="${1:-}" task="${2:-}"; shift 2 || usage 1
  check_name "$name"
  [[ -f "$task" ]] || die "task file not found: $task"
  local base="HEAD" setup="" effort="medium" check="" compare=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)   base="$2"; shift 2 ;;
      --setup)  setup="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --check)  check="$2"; shift 2 ;;
      --compare) compare="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  check_effort "$effort"
  local run="$STATE/runs/$name" wt="$STATE/wt/$name"
  [[ -e "$wt" ]] && die "worker '$name' already exists; use retry, accept or drop"
  git show-ref --quiet "refs/heads/brokkr/$name" && die "branch brokkr/$name already exists; drop it first"

  # Keep .brokkr out of git without touching the project's .gitignore.
  local exclude; exclude="$(git rev-parse --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF '.brokkr/' "$exclude" 2>/dev/null || echo '.brokkr/' >> "$exclude"

  ensure_strata
  mkdir -p "$run" "$STATE/wt"
  git rev-parse --verify "$base^{commit}" > "$run/base"
  git worktree add -q -b "brokkr/$name" "$wt" "$(cat "$run/base")"
  cp "$task" "$run/task.md"
  echo "$effort" > "$run/effort"
  [[ -n "$check" ]] && printf '%s\n' "$check" > "$run/check"
  uuidgen | tr 'A-Z' 'a-z' > "$run/session"
  if [[ -n "$setup" ]]; then
    echo "brokkr: running setup in the worktree: $setup"
    ( cd "$wt" && bash -c "$setup" ) > "$run/setup.log" 2>&1 || die "setup failed; see $run/setup.log"
  fi

  attempt "$name" 1 --session-id "$(cat "$run/session")" -p "$PREAMBLE$(cat "$run/task.md")"
  [[ -n "$compare" ]] && compare_run "$name" "$compare" "$setup"
  return 0
}

# The same task on an Anthropic model, in a detached throwaway worktree. Normal
# Claude Code auth, so this costs real usage. Only its tokens are kept.
compare_run() {
  local name="$1" model="$2" setup="$3"
  local run="$STATE/runs/$name" cwt="$STATE/wt/$name-cmp" rc=0 start end effort
  effort="$(cat "$run/effort")"
  git worktree add -q --detach "$cwt" "$(cat "$run/base")"
  [[ -n "$setup" ]] && { ( cd "$cwt" && bash -c "$setup" ) > "$run/compare-setup.log" 2>&1 || true; }
  echo "brokkr: A/B run of ${name} on ${model}..."
  start=$(date +%s)
  ( cd "$cwt" && run_bounded "$TIMEOUT" claude --model "$model" --effort "$effort" \
      --permission-mode acceptEdits --strict-mcp-config \
      --allowedTools "$ALLOW_TOOLS" --disallowedTools "$DENY_TOOLS" \
      --max-turns "$MAX_TURNS" --output-format stream-json --verbose \
      -p "$PREAMBLE$(cat "$run/task.md")" ) > "$run/compare.jsonl" 2> "$run/compare.err" || rc=$?
  end=$(date +%s)
  echo "  A/B finished in $(( (end-start)/60 ))m$(( (end-start)%60 ))s (exit $rc)"
  ledger worker "$name" 1 "$run/compare.jsonl" "$effort" "$start" "$end" compare
  if [[ -f "$run/check" ]]; then
    if ( cd "$cwt" && bash -c "$(cat "$run/check")" ) > "$run/compare.check.log" 2>&1; then
      echo "  A/B check: PASS"; else echo "  A/B check: FAIL -> $run/compare.check.log"; fi
  fi
  git worktree remove --force "$cwt"
}

cmd_retry() {
  local name="${1:-}" feedback="${2:-}"
  shift 2 || usage 1
  check_name "$name"
  local run="$STATE/runs/$name"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --effort) check_effort "${2:-}"; echo "$2" > "$run/effort"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -d "$STATE/wt/$name" ]] || die "no worker named '$name'"
  [[ -f "$feedback" ]] || die "feedback file not found: $feedback"
  ensure_strata
  local n=$(( $(cat "$run/attempts") + 1 ))
  cp "$feedback" "$run/feedback-$n.md"
  attempt "$name" "$n" --resume "$(cat "$run/session")" \
    -p "The reviewer checked your work and sends it back. Fix these points, run the checks again, and end with the same REPORT format.

$(cat "$feedback")"
}

cmd_quick() {
  local text="${1:-}"; shift || usage 1
  [[ -n "$text" ]] || die "quick needs the task text"
  local slug name
  slug="$(printf '%s' "$text" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | cut -c1-30 | sed 's/^-*//; s/-*$//')"
  name="q-${slug:-task}-$(date +%H%M%S)"
  mkdir -p "$STATE/tasks"
  printf '%s\n' "$text" > "$STATE/tasks/$name.md"
  echo "brokkr: worker name: $name"
  cmd_run "$name" "$STATE/tasks/$name.md" "$@"
}

ASK_PREAMBLE='You answer a question about this repository for a senior engineer who will not read the files. You may only read. Be short: at most about 300 words. Cite paths as path:line. Say "not found" when you cannot find it; do not guess.

QUESTION
'

# Read-only answer from the local model, in the repo root (no worktree).
cmd_ask() {
  local q="${1:-}"; shift || usage 1
  [[ -n "$q" ]] || die "ask needs a question"
  local effort="low"
  while [[ $# -gt 0 ]]; do
    case "$1" in --effort) effort="$2"; shift 2 ;; *) die "unknown option: $1" ;; esac
  done
  check_effort "$effort"
  local ALLOW_TOOLS="Read,Glob,Grep" DENY_TOOLS="Write,Edit,Bash,NotebookEdit,TodoWrite"
  ensure_strata
  mkdir -p "$STATE/asks"
  local out="$STATE/asks/$(date +%Y%m%d-%H%M%S).jsonl" key start end rc=0
  key="$(get_key)"; start=$(date +%s)
  ( cd "$ROOT" && run_bounded "$TIMEOUT" worker_claude "$key" --effort "$effort" -p "$ASK_PREAMBLE$q" ) > "$out" 2>/dev/null || rc=$?
  end=$(date +%s)
  ledger worker ask 1 "$out" "$effort" "$start" "$end" ask > /dev/null || true
  python3 - "$out" "$rc" <<'PY'
import json, sys
res = None
for line in open(sys.argv[1], errors="replace"):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") == "result":
        res = d
if res is None:
    print(f"brokkr ask: no answer (exit {sys.argv[2]})"); sys.exit(1)
print(res.get("result") or "(empty answer)")
PY
}

# Flags for the review packet: what a reviewer must look at in a worker diff.
review_flags() {
  local base="$1" ref="$2"
  { git diff --numstat "$base" "$ref"; echo "@@DIFF@@"; git diff -U0 "$base" "$ref"; } | python3 -c '
import re, sys
num, diff = sys.stdin.read().split("@@DIFF@@\n", 1)
flags = []
for line in num.splitlines():
    a, d, path = line.split("\t", 2)
    if d != "-" and int(d) > int(a) and re.search(r"(test|spec)", path, re.I):
        flags.append(f"test file {path} lost lines: -{d} +{a}")
pat = re.compile(r"TODO|FIXME|XXX|not implemented|\.skip\(|\.only\(|it\.todo|@ts-ignore|@ts-expect-error|eslint-disable|as any\b|pass\s*#")
f = None
for line in diff.splitlines():
    if line.startswith("+++ "):
        f = line[6:]
    elif line.startswith("+") and not line.startswith("+++") and pat.search(line):
        flags.append(f"{f}: {line[1:].strip()[:100]}")
print("\n".join(f"- FLAG: {x}" for x in flags[:15]) if flags else "- no flags")
'
}

# Commit with the repo's git identity, or a fallback when none is set.
git_commit() {
  local id=()
  git config user.email >/dev/null || id=(-c "user.name=${BROKKR_GIT_NAME:-brokkr}" -c "user.email=${BROKKR_GIT_EMAIL:-brokkr@localhost}")
  git "${id[@]+"${id[@]}"}" commit -q -m "$1"
}

# Run every open worker item of one phase of a task list, one after another.
cmd_batch() {
  local file="${1:-}" phase="${2:-}"; shift 2 || usage 1
  [[ -f "$file" ]] || die "task list not found: $file"
  local effort="medium" retries=3 setup=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --effort)  effort="$2"; shift 2 ;;
      --retries) retries="$2"; shift 2 ;;
      --setup)   setup="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  check_effort "$effort"
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "commit or stash your changes first; the batch commits each item"
  ensure_strata
  local ts packet log items
  ts="$(date +%Y%m%d-%H%M%S)"; packet="$STATE/batch-$ts.md"; log="$STATE/batch-$ts.log"
  mkdir -p "$STATE/tasks"
  # One line per open worker item: check<TAB>text. Items marked **Claude:** are skipped.
  items="$(python3 - "$file" "$phase" <<'PY'
import re, sys
text, phase = open(sys.argv[1]).read(), sys.argv[2]
glob = re.search(r"^Check:\s*`([^`]+)`", text, re.M)
glob = glob.group(1) if glob else ""
inside = False
for line in text.splitlines():
    if line.startswith("## "):
        inside = re.match(rf"## {re.escape(phase)}[.\s]", line) is not None
        continue
    m = re.match(r"- \[ \] (.+)$", line)
    if inside and m and not m.group(1).startswith("**Claude:**"):
        item = m.group(1)
        c = re.search(r"\(check:\s*`([^`]+)`\)", item)
        print(f"{c.group(1) if c else glob}\t{item}")
PY
)"
  [[ -n "$items" ]] || die "no open worker items in phase $phase of $file"
  ledger event begin -
  { echo "# Batch $ts: $file, phase $phase"; echo; } > "$packet"
  echo "brokkr: batch phase $phase, $(printf '%s\n' "$items" | wc -l | tr -d ' ') item(s). Packet: $packet"

  local check item name tf n ok
  while IFS=$'\t' read -r check item; do
    name="b$phase-$(printf '%s' "$item" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | cut -c1-28 | sed 's/^-*//; s/-*$//')-$(date +%H%M%S)"
    tf="$STATE/tasks/$name.md"
    printf '%s\n\nContext: this item comes from %s, phase %s. Read that file for the whole plan, but do not edit it.\nCheck: %s\n' \
      "$item" "$file" "$phase" "${check:-none}" > "$tf"
    echo "brokkr: [$name] $item"
    cmd_run "$name" "$tf" --effort "$effort" ${check:+--check "$check"} ${setup:+--setup "$setup"} >> "$log" 2>&1 < /dev/null
    n=1; ok=no
    while :; do
      if [[ -z "$check" || "$(cat "$STATE/runs/$name/check.status" 2>/dev/null)" == pass ]]; then ok=yes; break; fi
      (( n > retries )) && break
      n=$((n+1))
      { echo "The check \`$check\` failed. Fix the cause, not the test. Last lines of its output:"; echo '```'
        tail -60 "$STATE/runs/$name/attempt-$((n-1)).check.log"; echo '```'; } > "$STATE/tasks/$name.fb-$n.md"
      echo "  check failed; local retry $((n-1)) of $retries"
      cmd_retry "$name" "$STATE/tasks/$name.fb-$n.md" >> "$log" 2>&1 < /dev/null
    done
    local base; base="$(cat "$STATE/runs/$name/base")"
    {
      echo "## $item"
      echo "- worker: \`$name\`, attempts: $n, check: $([[ $ok == yes ]] && echo PASS || echo FAIL)"
      echo "- files: $(git diff --stat "$base" "brokkr/$name" | tail -1 | sed 's/^ *//')"
      git diff --stat=100 "$base" "brokkr/$name" | sed '$d; s/^ */  - /'
      echo "- worker notes: $(grep -m1 '^Notes:' "$STATE/runs/$name/attempt-$n.report.md" 2>/dev/null | cut -c8- || echo none)"
      review_flags "$base" "brokkr/$name"
    } >> "$packet"
    if [[ $ok == yes ]]; then
      cmd_accept "$name" >> "$log" 2>&1 < /dev/null
      python3 - "$file" "$item" <<'PY'
import sys
p, item = sys.argv[1], sys.argv[2]
s = open(p).read().replace(f"- [ ] {item}", f"- [x] {item}", 1)
open(p, "w").write(s)
PY
      git add -A "$file" && git_commit "brokkr: $item"
      echo "  done in $n attempt(s), committed $(git rev-parse --short HEAD)"
      echo "- commit: $(git rev-parse --short HEAD)" >> "$packet"; echo >> "$packet"
    else
      echo "- LEFT OPEN for Claude: worktree $STATE/wt/$name" >> "$packet"
      echo "  FAILED after $n attempt(s); worktree kept, batch stopped. See $packet"
      break
    fi
  done <<< "$items"
  echo "brokkr: batch finished. Review packet: $packet"
}

cmd_status() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    ls "$STATE/runs" 2>/dev/null || echo "brokkr: no workers"
    return
  fi
  check_name "$name"
  local run="$STATE/runs/$name"
  [[ -d "$run" ]] || die "no worker named '$name'"
  local n; n="$(cat "$run/attempts" 2>/dev/null || echo 0)"
  echo "worker: $name   attempts: $n   effort: $(cat "$run/effort")   base: $(cut -c1-10 "$run/base")"
  [[ "$n" -gt 0 ]] && sed 's/^/  /' "$run/attempt-$n.summary"
  echo "  diff: $(git diff --shortstat "$(cat "$run/base")" "brokkr/$name" | sed 's/^ *//')"
}

cmd_accept() {
  local name="${1:-}"
  check_name "$name"
  git show-ref --quiet "refs/heads/brokkr/$name" || die "no branch brokkr/$name"
  git merge --squash "brokkr/$name" >/dev/null || die "squash merge failed; resolve it, then run: forge.sh drop $name"
  echo "brokkr: $name is staged in $(git branch --show-current). Review it and commit."
  ledger event accept "$name"
  cmd_drop "$name"
}

cmd_drop() {
  local name="${1:-}"
  check_name "$name"
  [[ -d "$STATE/wt/$name" ]] && git worktree remove --force "$STATE/wt/$name"
  git show-ref --quiet "refs/heads/brokkr/$name" && git branch -q -D "brokkr/$name"
  if [[ -d "$STATE/runs/$name" ]]; then  # keep the worker logs as history
    mkdir -p "$STATE/logs"
    cp -R "$STATE/runs/$name" "$STATE/logs/$name-$(date +%Y%m%d-%H%M%S)"
    rm -rf "$STATE/runs/$name"
  fi
  ledger event drop "$name"
  echo "brokkr: dropped $name"
}

case "${1:-}" in
  run)    shift; cmd_run "$@" ;;
  quick)  shift; cmd_quick "$@" ;;
  ask)    shift; cmd_ask "$@" ;;
  batch)  shift; cmd_batch "$@" ;;
  begin)  ledger event begin - ;;
  report) [[ -f "$LEDGER" ]] || die "no ledger yet"; ledger report --session-log "$(ls "$HOME"/.claude/projects/*/"${CLAUDE_CODE_SESSION_ID:-none}".jsonl 2>/dev/null | head -1)" ;;
  retry)  shift; cmd_retry "$@" ;;
  status) shift; cmd_status "$@" ;;
  accept) shift; cmd_accept "$@" ;;
  drop)   shift; cmd_drop "$@" ;;
  -h|--help|"") usage ;;
  *) usage 1 ;;
esac

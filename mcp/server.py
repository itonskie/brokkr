#!/usr/bin/env python3
"""brokkr MCP server: gives Claude Code tools that hand work to the local
model through forge.sh. Standard library only; MCP over stdio (one JSON-RPC
message per line).

Every tool runs forge.sh in the project directory and returns its output as
text. The calls block until the local model finishes, which can take minutes;
Claude spends no tokens while it waits.
"""
import glob, json, os, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
FORGE = os.path.join(HERE, "..", "skills", "delegate", "scripts", "forge.sh")
EFFORT = {"type": "string", "enum": ["low", "medium", "high"]}

TOOLS = [
    {"name": "local_ask",
     "description": "Ask the local model a question about this repository instead of reading the files yourself. "
                    "It reads the code (read-only) and returns a short answer with path:line references. "
                    "Use it before reading more than two or three files to understand something. Free: it uses no Claude usage.",
     "inputSchema": {"type": "object", "additionalProperties": False, "required": ["question"],
                     "properties": {"question": {"type": "string", "description": "A precise question, e.g. 'Where is the fuse map built and what does it return?'"},
                                    "effort": EFFORT}}},
    {"name": "local_task",
     "description": "Send one implementation task to the local worker. It works in its own git worktree on branch brokkr/<name>, "
                    "runs the check command, and returns a summary (result, turns, diff size, check PASS/FAIL, worker name). "
                    "Then review with git diff and call local_accept, local_retry or local_drop. "
                    "Write the task as 3-6 lines: goal, files to read or change, a pattern to copy, the check command.",
     "inputSchema": {"type": "object", "additionalProperties": False, "required": ["task", "check"],
                     "properties": {"task": {"type": "string"},
                                    "check": {"type": "string", "description": "Shell command that must pass, e.g. 'npm test && npm run build'"},
                                    "effort": EFFORT,
                                    "setup": {"type": "string", "description": "Command run in the fresh worktree first, e.g. 'npm ci'"}}}},
    {"name": "local_retry",
     "description": "Send a worker's result back with feedback. The worker resumes its own session.",
     "inputSchema": {"type": "object", "additionalProperties": False, "required": ["name", "feedback"],
                     "properties": {"name": {"type": "string"}, "feedback": {"type": "string"}, "effort": EFFORT}}},
    {"name": "local_accept",
     "description": "Squash a worker's branch into the current branch (staged, not committed) and remove its worktree. Commit afterwards.",
     "inputSchema": {"type": "object", "additionalProperties": False, "required": ["name"],
                     "properties": {"name": {"type": "string"}}}},
    {"name": "local_drop",
     "description": "Delete a worker's worktree, branch and run files.",
     "inputSchema": {"type": "object", "additionalProperties": False, "required": ["name"],
                     "properties": {"name": {"type": "string"}}}},
    {"name": "local_report",
     "description": "Usage report: Claude usage spent per item versus usage the local worker saved.",
     "inputSchema": {"type": "object", "additionalProperties": False, "properties": {}}},
]


def cwd_root():
    return os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def short(c):
    """One line for a tool call, e.g. 'Read src/data/schema.ts'."""
    inp = c.get("input") or {}
    arg = str(next((inp[k] for k in ("file_path", "command", "pattern", "path") if inp.get(k)), ""))
    if "/.brokkr/wt/" in arg:  # worktree path -> path inside the repo
        arg = arg.split("/.brokkr/wt/", 1)[1].partition("/")[2]
    arg = arg.replace(cwd_root() + "/", "")
    line = f"{c.get('name')} {arg}".strip().replace("\n", " ")
    return line if len(line) <= 100 else line[:97] + "..."


def watch(cwd, start, send, done):
    """Follow the newest worker log written after start and call send(text)
    for each tool call and each failed tool result."""
    pattern = [os.path.join(cwd, ".brokkr", "runs", "*", "*.jsonl"),
               os.path.join(cwd, ".brokkr", "asks", "*.jsonl")]
    path, f = None, None
    while True:
        files = [p for g in pattern for p in glob.glob(g) if os.path.getmtime(p) >= start]
        if files:
            newest = max(files, key=os.path.getmtime)
            if newest != path:  # first log, or a retry started a new attempt
                if f:
                    f.close()
                path, f = newest, open(newest)
        line = f.readline() if f else ""
        if not line:
            if done.is_set():
                break
            time.sleep(0.5)
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        content = (ev.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for c in content:
            if ev.get("type") == "assistant" and c.get("type") == "tool_use":
                send(short(c))
            elif ev.get("type") == "user" and c.get("type") == "tool_result" and c.get("is_error"):
                send("  failed: " + str(c.get("content"))[:80].replace("\n", " "))
    if f:
        f.close()


def forge(*args, progress=None):
    cwd = cwd_root()
    start = time.time() - 1
    p = subprocess.Popen(["bash", FORGE, *args], cwd=cwd, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    done, t = threading.Event(), None
    if progress:
        t = threading.Thread(target=watch, args=(cwd, start, progress, done), daemon=True)
        t.start()
    stdout, stderr = p.communicate()
    done.set()
    if t:
        t.join(timeout=5)
    out = (stdout + ("\n" + stderr if stderr.strip() else "")).strip()
    return out or f"(no output, exit {p.returncode})", p.returncode != 0


def tmpfile(name, text):
    cwd = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    d = os.path.join(cwd, ".brokkr", "tasks")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name)
    with open(path, "w") as f:
        f.write(text + "\n")
    return path


def call(name, a, progress=None):
    eff = ["--effort", a["effort"]] if a.get("effort") else []
    if name == "local_ask":
        return forge("ask", a["question"], *eff, progress=progress)
    if name == "local_task":
        extra = ["--setup", a["setup"]] if a.get("setup") else []
        return forge("quick", a["task"], "--check", a["check"], *eff, *extra, progress=progress)
    if name == "local_retry":
        path = tmpfile(f"{a['name']}.feedback.md", a["feedback"])
        return forge("retry", a["name"], path, *eff, progress=progress)
    if name == "local_accept":
        return forge("accept", a["name"])
    if name == "local_drop":
        return forge("drop", a["name"])
    if name == "local_report":
        return forge("report")
    return f"unknown tool {name}", True


LOCK = threading.Lock()


def write(msg):
    with LOCK:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()


def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    msg.update({"error": error} if error else {"result": result})
    write(msg)


def progress_sender(token):
    """notifications/progress for one call, or None if the client sent no token."""
    if token is None:
        return None
    count = [0]

    def send(text):
        count[0] += 1
        write({"jsonrpc": "2.0", "method": "notifications/progress",
               "params": {"progressToken": token, "progress": count[0], "message": text}})
    return send


for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError:
        continue
    method, id_ = req.get("method"), req.get("id")
    if id_ is None:
        continue  # notifications need no answer
    if method == "initialize":
        reply(id_, {"protocolVersion": req.get("params", {}).get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "brokkr", "version": "0.1.0"}})
    elif method == "tools/list":
        reply(id_, {"tools": TOOLS})
    elif method == "tools/call":
        p = req.get("params", {})
        send = progress_sender((p.get("_meta") or {}).get("progressToken"))
        try:
            text, err = call(p.get("name"), p.get("arguments") or {}, send)
        except Exception as e:  # report, do not crash the server
            text, err = f"brokkr error: {e}", True
        reply(id_, {"content": [{"type": "text", "text": text}], "isError": err})
    elif method == "ping":
        reply(id_, {})
    else:
        reply(id_, error={"code": -32601, "message": f"method not found: {method}"})

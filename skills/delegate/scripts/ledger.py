#!/usr/bin/env python3
"""ledger.py - token ledger for brokkr: what the local worker used, what the
orchestrating Claude Code session spent, and what it would cost on Anthropic.

  ledger.py event  <ledger> <kind> <name> [key=value ...]     append one event
  ledger.py worker <ledger> <name> <attempt> <stream.jsonl> <effort> <start> <end> [kind]
  ledger.py report <ledger> [--session-log FILE]

Prices are Anthropic first-party API rates in USD per million tokens. Cache
writes are priced at 1.25x input (5 minute cache) unless the log says 1 hour.
"""
import json, sys, time
from datetime import datetime, timezone

PRICES = {  # input, output, cache read, cache write 5m, cache write 1h
    "opus":   (4.00, 20.00, 0.20, 5.00, 8.00),
    "sonnet": (2.00, 10.00, 0.20, 2.50, 4.00),
}


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def append(ledger, rec):
    with open(ledger, "a") as f:
        f.write(json.dumps(rec) + "\n")


def usage_of(messages):
    """Sum usage over assistant messages, counting each message id once (stream
    output repeats a message once per content block)."""
    last = {}
    for m in messages:
        last[m.get("id") or id(m)] = m.get("usage") or {}
    t = dict(input=0, output=0, cache_read=0, cache_write_5m=0, cache_write_1h=0, calls=len(last))
    for u in last.values():
        t["input"] += u.get("input_tokens") or 0
        t["output"] += u.get("output_tokens") or 0
        t["cache_read"] += u.get("cache_read_input_tokens") or 0
        cc = u.get("cache_creation") or {}
        h1 = cc.get("ephemeral_1h_input_tokens") or 0
        t["cache_write_1h"] += h1
        t["cache_write_5m"] += (u.get("cache_creation_input_tokens") or 0) - h1
    return t


def cost(t, family):
    i, o, cr, w5, w1 = PRICES[family]
    return (t["input"] * i + t["output"] * o + t["cache_read"] * cr
            + t["cache_write_5m"] * w5 + t["cache_write_1h"] * w1) / 1e6


def cmd_event(ledger, kind, name, *kv):
    rec = {"kind": kind, "name": name, "time": now()}
    rec.update(a.split("=", 1) for a in kv)
    append(ledger, rec)


def cmd_worker(ledger, name, attempt, stream, effort, start, end, kind="worker"):
    msgs, result = [], {}
    for line in open(stream, errors="replace"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("type") == "assistant":
            msgs.append(d.get("message") or {})
        elif d.get("type") == "result":
            result = d
    rec = {"kind": kind, "name": name, "attempt": int(attempt), "effort": effort,
           "start": datetime.fromtimestamp(int(start), timezone.utc).isoformat(timespec="seconds"),
           "end": datetime.fromtimestamp(int(end), timezone.utc).isoformat(timespec="seconds"),
           "seconds": int(end) - int(start), "turns": result.get("num_turns"),
           "model": (msgs[-1].get("model") if msgs else None),
           "reported_cost_usd": result.get("total_cost_usd"),
           # The result line has the session totals; per-message usage in the
           # stream is written before output is known, so it is only a fallback.
           "usage": usage_of([{"id": "result", "usage": result["usage"]}]) if result.get("usage") else usage_of(msgs)}
    rec["usage"]["calls"] = len({m.get("id") for m in msgs})
    append(ledger, rec)
    u = rec["usage"]
    print(f"  tokens: in {u['input']:,}  cache read {u['cache_read']:,}  cache write "
          f"{u['cache_write_5m'] + u['cache_write_1h']:,}  out {u['output']:,}"
          + ("" if kind != "worker" else f"   (same tokens on Opus 5.5: ${cost(u, 'opus'):.3f})"))


def session_usage(log, t0, t1):
    """The orchestrator's own usage between two times, from its transcript."""
    msgs = []
    for line in open(log, errors="replace"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        m = d.get("message")
        if d.get("type") != "assistant" or not isinstance(m, dict) or not m.get("usage"):
            continue
        ts = d.get("timestamp", "")
        if t0[:19] <= ts[:19] <= t1[:19] and str(m.get("model", "")).startswith("claude"):
            msgs.append(m)
    return usage_of(msgs)


def tok(t):
    """Tokens in (fresh input + cache writes), cache reads, and out."""
    return (t["input"] + t["cache_write_5m"] + t["cache_write_1h"], t["cache_read"], t["output"])


def ftok(t):
    if not t:
        return f"{'-':>28}"
    a, b, c = tok(t)
    return f"{a:>8,} {b:>10,} {c:>7,}"


def family(model):
    m = model or ""
    return "sonnet" if "sonnet" in m else "opus"


def zero():
    return dict(input=0, output=0, cache_read=0, cache_write_5m=0, cache_write_1h=0, calls=0)


def add(a, b):
    return {k: a[k] + b.get(k, 0) for k in a}


def cmd_report(ledger, *args):
    log = args[args.index("--session-log") + 1] if "--session-log" in args else None
    try:
        log = log if log and open(log) else None
    except OSError:
        log = None
    recs = [json.loads(l) for l in open(ledger) if l.strip()]
    marks = [r for r in recs if r["kind"] in ("begin", "accept", "drop")]
    items = {}
    for r in recs:
        if r["kind"] in ("worker", "compare"):
            items.setdefault(r["name"], {"worker": [], "compare": []})[r["kind"]].append(r)

    print("Tokens: in = fresh input + cache writes, cache = cache reads, out = output.")
    print("Weight = API-price equivalent. Plan limits are weighted the same way, so it")
    print("shows how fast each side fills your plan. It is not a bill.\n")
    hdr = f"{'in':>8} {'cache':>10} {'out':>7}"
    print(f"{'item':30} {'eff':6} {'att':>3} | SPENT: orchestrator (Opus) {'':2}| SAVED: local worker (Qwen) {'':2}| A/B: same task on Anthropic")
    print(f"{'':30} {'':6} {'':>3} | {hdr} {'weight':>7} | {hdr} {'~weight':>7} | {hdr} {'weight':>7}")
    T = dict(orch=zero(), work=zero(), cmp=zero(), o=0.0, w=0.0, c=0.0, o_cmp=0.0, n_cmp=0)
    for name, it in items.items():
        w = it["worker"]
        wt = zero()
        for a in w:
            wt = add(wt, a["usage"])
        w_wt = cost(wt, "opus")
        start = w[0]["start"] if w else ""
        before = [m["time"] for m in marks if m["time"] <= start]
        after = [m["time"] for m in marks if m["name"] == name and m["kind"] in ("accept", "drop")]
        orch = session_usage(log, before[-1], after[-1]) if (log and before and after) else None
        o_wt = cost(orch, "opus") if orch else 0.0
        ct, c_wt = None, 0.0
        for a in it["compare"]:
            ct = add(ct or zero(), a["usage"]); c_wt += cost(a["usage"], family(a.get("model")))
        T["work"] = add(T["work"], wt); T["w"] += w_wt
        if orch:
            T["orch"] = add(T["orch"], orch); T["o"] += o_wt
        if ct:
            T["cmp"] = add(T["cmp"], ct); T["c"] += c_wt; T["o_cmp"] += o_wt; T["n_cmp"] += 1
        print(f"{name[:30]:30} {(w[-1]['effort'] if w else '-'):6} {len(w):>3} | {ftok(orch)} {o_wt if orch else 0:>7.3f} | "
              f"{ftok(wt)} {w_wt:>7.3f} | {ftok(ct)} {c_wt if ct else 0:>7.3f}")

    print(f"{'TOTAL':30} {'':6} {'':>3} | {ftok(T['orch'])} {T['o']:>7.3f} | {ftok(T['work'])} {T['w']:>7.3f} | "
          f"{ftok(T['cmp']) if T['n_cmp'] else ftok(None)} {T['c']:>7.3f}")
    asks = [r for r in recs if r["kind"] == "ask"]
    if asks:
        at = zero()
        for a in asks:
            at = add(at, a["usage"])
        print(f"{'local asks (' + str(len(asks)) + ')':30} {'':6} {'':>3} | {ftok(None)} {0:>7.3f} | {ftok(at)} {cost(at, 'opus'):>7.3f} |")
        T["w"] += cost(at, "opus")
    print()
    if T["n_cmp"]:
        print(f"Real A/B on {T['n_cmp']} item(s): doing the work on Anthropic used weight {T['c']:.3f}; "
              f"delegating cost the orchestrator {T['o_cmp']:.3f}.")
        print(f"  Net on those items: {T['c'] - T['o_cmp']:+.3f} weight (positive = the hybrid used less of your plan).")
    if T["o"] or T["w"]:
        print(f"Estimate for all items: the worker's tokens at Opus weight = {T['w']:.3f}; the orchestrator spent {T['o']:.3f}.")
        print(f"  Net: {T['w'] - T['o']:+.3f} weight. The estimate ignores tokenizer and turn differences; the A/B column does not.")
    if not log:
        print("No session transcript found, so orchestrator usage is missing. Run forge.sh from inside Claude Code.")
    print("Orchestrator usage counts everything this session did between the item's start mark and its accept/drop.")


if __name__ == "__main__":
    cmd, *rest = sys.argv[1:] or ["help"]
    {"event": cmd_event, "worker": cmd_worker, "report": cmd_report}.get(cmd, lambda *a: print(__doc__))(*rest)

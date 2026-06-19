#!/usr/bin/env python3
"""mux web — a tiny local UI over the mux queue. Python stdlib only, no deps.

Launched in a repo via `mux web`; serves that repo's .mux/ queue at
http://127.0.0.1:<port>. Three things, nothing to memorize:
  • watch the headless output's live log  (read-only — it cannot be reprompted)
  • see the task list, and act with buttons  (release / approve / answer / fail)
  • a button to open a channel in a real terminal

All state lives in .mux/ and every action shells out to the `mux` backend — this
server holds no logic of its own.
"""
import json, os, re, subprocess, time, urllib.parse
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.environ.get("MUX_REPO", os.getcwd())
MUX  = os.environ.get("MUX_BIN", "mux")
PORT = int(os.environ.get("MUX_PORT", "8770"))   # not 7000: macOS AirPlay uses it
WEB  = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")   # vendored marked + theme
PROMPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompts")  # role prompts (CHANNEL.md, …)

# Provider→theme map: the UI accent + supporting pastels + header label come from
# ONE place here, so re-skinning for a different output backend = changing/adding
# one entry and setting MUX_PROVIDER. Unknown providers fall back to "generic".
# The default (claude) is a warm, mellow dark-on-cream look. The `accent` is NOT
# a hue here — it's a bright warm cream used purely as a "live/active/hover"
# highlight (it brightens against the grey defaults rather than coloring). Real
# hue is reserved for meaning: mint/lilac/pink status pastels + the terminal log
# roles. The success/subagent/danger roles are status semantics (shared across
# providers); only `accent` and `label` are brand-specific.
_PASTELS = {"success": "#aed99a", "subagent": "#c9aef0", "danger": "#e8a0ac"}
THEMES = {
    "claude":  {"accent": "#e3ddd1", "label": "Claude",   **_PASTELS},
    "openai":  {"accent": "#6cc0a4", "label": "OpenAI",   **_PASTELS},
    "gemini":  {"accent": "#8badf0", "label": "Gemini",   **_PASTELS},
    "generic": {"accent": "#a89e8e", "label": "Output", **_PASTELS},
}

def theme():
    """The active provider's theme (accent/pastels + label), from MUX_PROVIDER."""
    return THEMES.get(os.environ.get("MUX_PROVIDER", "claude"), THEMES["generic"])


def mux(*args):
    """Run a mux verb in the repo; return (ok, combined_output)."""
    r = subprocess.run(["bash", MUX, *args], cwd=REPO,
                       capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def tasks():
    ok, out = mux("status", "--json")
    try:
        return json.loads(out) if ok else []
    except json.JSONDecodeError:
        return []


def git_dirty_nonmux():
    """True if the tree has changes OUTSIDE .mux/ — exactly what blocks the output
    (mirrors mux.sh git_clean: the .mux/ queue is metadata, never counts as work)."""
    r = subprocess.run(["git", "status", "--porcelain"], cwd=REPO,
                       capture_output=True, text=True)
    for line in r.stdout.splitlines():
        path = line[3:]
        if path and not (path == ".mux" or path.startswith(".mux/")):
            return True
    return False


def git_branch_state():
    """The current branch and its push/pull standing vs upstream, for the header
    chip. Read-only and defensive — mirrors git_dirty_nonmux: it must never raise,
    so every git call is guarded and falls back to a safe dict.

    Returns {"branch": <name>, "upstream": <bool>, "ahead": <int|null>,
    "behind": <int|null>, "dirty": <int>}. branch is "(detached)" on a detached
    HEAD. ahead/behind are null when there is no upstream; otherwise counted as of
    the LAST fetch (we never auto-fetch here), so "behind" may be stale — that's
    acceptable. dirty is the count of changed files OUTSIDE .mux/ (same rule as
    git_dirty_nonmux: the .mux/ queue is metadata, never counts as work)."""
    safe = {"branch": "", "upstream": False, "ahead": None, "behind": None,
            "dirty": 0}
    try:
        st = subprocess.run(["git", "status", "--porcelain"], cwd=REPO,
                           capture_output=True, text=True)
        dirty = sum(1 for ln in st.stdout.splitlines()
                    if (p := ln[3:]) and not (p == ".mux" or p.startswith(".mux/")))
        safe["dirty"] = dirty
        r = subprocess.run(["git", "branch", "--show-current"], cwd=REPO,
                           capture_output=True, text=True)
        branch = r.stdout.strip()
        safe["branch"] = branch if branch else "(detached)"
        u = subprocess.run(["git", "rev-parse", "--abbrev-ref",
                            "--symbolic-full-name", "@{u}"], cwd=REPO,
                           capture_output=True, text=True)
        if u.returncode != 0:
            return safe
        c = subprocess.run(["git", "rev-list", "--left-right", "--count",
                            "@{u}...HEAD"], cwd=REPO, capture_output=True, text=True)
        if c.returncode != 0:
            return safe
        behind, ahead = c.stdout.split()
        return {"branch": safe["branch"], "upstream": True,
                "ahead": int(ahead), "behind": int(behind), "dirty": dirty}
    except (OSError, ValueError):
        return safe


def auto_enabled():
    """True when auto mode is ON — persisted as the EXISTENCE of .mux/auto (on
    disk so it survives restart, inside .mux/ so it never counts as work)."""
    return os.path.exists(os.path.join(REPO, ".mux", "auto"))


def autopilot():
    """One hands-off cycle, piggy-backed on the /api/tasks poll when auto is ON.
    Flips ONLY the approve gate — auto-commits a finished RUNNING task so the
    queue keeps flowing — and never auto-claims, reverts, fails, or resolves.

    It does NOT release drafts: auto mode is a transient executor behavior, not a
    status rewrite. The executor runs DRAFTs in place while auto is on (mux.sh
    auto_on), so toggling auto off mutates nothing on disk — every task keeps its
    status and its Release/Approve button simply reappears.

    Auto-approve fires only when a finished RUNNING task is genuinely waiting:
    it exists, its tick is NOT in flight, it is not flagged interrupted, and the
    tree is dirty outside .mux/ (real work to commit). Any miss → do nothing
    this cycle (never `mux ok` a clean tree — it would die — or a live tick)."""
    if status()["executing"]:
        return
    ts = tasks()
    running = next((t for t in ts if t.get("status") == "RUNNING"), None)
    if running and not running.get("interrupted") and git_dirty_nonmux():
        mux("ok")


def idle_reason():
    """Why is nothing running right now? None when the output has/holds work
    (a cycle is mid-flight, or `mux next` has a task) — the log speaks for itself then."""
    if os.path.isdir(os.path.join(REPO, ".mux", "tick.lock")):
        return None                       # a cycle is running; let its log show
    ok, nxt = mux("next")
    if ok and nxt.strip():
        return None                       # work is queued; about to run
    ts = tasks()
    running = any(t.get("status") == "RUNNING" for t in ts)
    ready   = any(t.get("status") == "READY"   for t in ts)
    if git_dirty_nonmux():
        if running:
            return ("Idle — a finished task is awaiting your approval. "
                    "Approve or revert it to free the output.")
        if ready:
            return ("Idle — the working tree has uncommitted changes outside .mux/. "
                    "The output only runs from a clean tree — commit or stash them to start.")
        return "Idle — uncommitted changes outside .mux/."
    if ready:
        return "Idle — the next task is waiting on a dependency."
    return "No activity"


def status():
    """Live output state for the page's working indicator.
    executing = a tick is in flight (.mux/tick.lock exists); elapsed = seconds
    since the lock dir was created (its mtime), or None if unreadable/idle."""
    lock = os.path.join(REPO, ".mux", "tick.lock")
    if not os.path.isdir(lock):
        return {"executing": False, "elapsed": None, "git": git_branch_state()}
    try:
        elapsed = int(time.time() - os.path.getmtime(lock))
    except OSError:
        elapsed = None
    return {"executing": True, "elapsed": elapsed, "git": git_branch_state()}


def _clip(s):
    """Collapse whitespace and truncate to one tidy ~90-char line."""
    s = " ".join(str(s).split())
    return s[:88] + "…" if len(s) > 90 else s


def tool_line(blk):
    """A readable one-liner for a tool_use event: what it's actually doing."""
    name = blk.get("name", "tool")
    inp = blk.get("input", {}) or {}
    if name == "Bash":
        d = inp.get("command", "")
    elif name in ("Read", "Edit", "Write", "NotebookEdit"):
        d = os.path.basename(inp.get("file_path", ""))
    elif name in ("Grep", "Glob"):
        d = inp.get("pattern", inp.get("query", ""))
    elif name in ("Task", "Agent"):
        d = inp.get("description", "")
    else:
        d = ""
    d = _clip(d)
    return f"→ {name}: {d}" if d else f"→ {name}"


def _fmt_dur(ms):
    """ms → human-readable like `3m51s` or `9s`."""
    s = int(ms) // 1000
    return f"{s // 60}m{s % 60}s" if s >= 60 else f"{s}s"


def _fmt_tok(n):
    """Token count with a `k` suffix when ≥1000."""
    n = int(n)
    return f"{n / 1000:.1f}k" if n >= 1000 else str(n)


def result_summary(ev):
    """Compact stats line (`Σ …`) from a `result` event's fields; omit any
    missing segment, never crash."""
    segs = []
    if ev.get("duration_ms") is not None:
        segs.append(_fmt_dur(ev["duration_ms"]))
    if ev.get("num_turns") is not None:
        segs.append(f"{ev['num_turns']} turns")
    usage = ev.get("usage") or {}
    out_t, in_t = usage.get("output_tokens"), usage.get("input_tokens")
    if out_t is not None or in_t is not None:
        segs.append(f"{_fmt_tok(out_t or 0)} out / {_fmt_tok(in_t or 0)} in tok")
    # Deliberately omit `total_cost_usd`: it's the API-equivalent price of the
    # tokens, which is meaningless (and misleading) on a Claude subscription
    # where usage isn't billed per token.
    return "Σ " + " · ".join(segs) if segs else ""


# Short, fun kickoff phrases riffing on the MULTIPLEXER / channels / signals
# lingo, rendered as the cycle divider in the output log. 12 entries;
# cycle_divider indexes with a stride coprime to 12 so the banner walks the
# whole list deterministically without real randomness.
_CYCLE_PHRASES = [
    "switching channels…",
    "routing the next signal…",
    "the bus is hot…",
    "multiplexing resumes…",
    "patching in a fresh channel…",
    "the switch flips through…",
    "fanning out the queue…",
    "signal on the wire…",
    "the executor wakes…",
    "tapping the stream…",
    "throughput climbing…",
    "channels live…",
]


def cycle_divider(gen):
    """Return the kickoff banner for a new cycle: a single bright "▶"-led log
    item carrying one of the themed phrases. `gen` (the 0-based cycle index)
    picks the phrase deterministically — no randomness — but a stride coprime
    with the pool length (7 vs 12) walks the whole list so consecutive runs
    jump around and feel random. The leading "▶" makes the UI style it as its
    own bright divider line (class `lk`)."""
    return ["▶ " + _CYCLE_PHRASES[(max(0, gen) * 7) % len(_CYCLE_PHRASES)]]


def log_lines(limit=300):
    """Render the latest tick log (Claude stream-json) into readable lines.

    Returns a list whose items are either plain strings (the readable event
    stream) or, for long/multi-line assistant markdown messages, dicts of the
    form {"glyph","md"} — the full markdown body, which the UI renders inline
    as formatted markdown (via marked.js) instead of as a plain log line."""
    path = os.path.join(REPO, ".mux", "log", "output.jsonl")
    out = []
    try:
        with open(path) as f:
            raw = f.readlines()[-limit:]
    except OSError:
        return [idle_reason() or "Starting…"]
    cycle = 0
    thinking = False  # whether the last rendered line is the "thinking…" line
    for line in raw:
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = ev.get("type")
        if t == "system":
            sub = ev.get("subtype")
            if sub == "init":
                # An `init` event is the only true per-`claude -p` boundary
                # (it carries a fresh session_id). All other system subtypes
                # (thinking_tokens, hook_started, …) must NOT draw a divider.
                cycle += 1
                # The number is never shown; we only use it to pick WHICH
                # phrase the divider shows, so successive run dividers walk the
                # phrase pool. cycle 1 → phrase index 0.
                out.extend(cycle_divider(cycle - 1))
                thinking = False
            elif sub == "thinking_tokens":
                # Collapse consecutive thinking events into one muted line.
                if not thinking:
                    out.append("  · thinking…")
                    thinking = True
            elif sub == "task_started":
                # Sub-agent (Task tool) kickoff. NOT a cycle boundary.
                d = ev.get("description") or ev.get("task_type") or "task"
                out.append("⌖ sub-agent: " + _clip(d))
                thinking = False
            elif sub == "task_notification":
                # Sub-agent outcome (typically status "completed").
                st = ev.get("status", "done")
                out.append("⌖ sub-agent " + st + ": " + _clip(ev.get("summary", "")))
                thinking = False
            # any other system subtype: ignore (no divider, no crash)
        elif t == "assistant":
            for blk in ev.get("message", {}).get("content", []):
                if blk.get("type") == "text" and blk.get("text", "").strip():
                    txt = blk["text"].strip()
                    # Long / multi-line markdown messages render inline as
                    # formatted markdown (via marked.js, see index.html) so
                    # headings/bold/lists read properly instead of dumping raw
                    # ## / ** noise into the log. Short one-liners stay inline as
                    # a plain event line.
                    if "\n" in txt or len(txt) > 200:
                        out.append({"glyph": "●", "md": txt})
                    else:
                        out.append("● " + txt)
                    thinking = False
                elif blk.get("type") == "tool_use":
                    out.append(tool_line(blk))
                    thinking = False
        elif t == "user":
            # Tool outcomes. Surface ONLY failures to keep the panel readable;
            # successful results are implied by the assistant's next move.
            tur = ev.get("tool_use_result") or {}
            for blk in ev.get("message", {}).get("content", []):
                if blk.get("type") != "tool_result":
                    continue
                if blk.get("is_error") or tur.get("interrupted"):
                    msg = blk.get("content") or tur.get("stderr") or tur.get("stdout") or ""
                    if isinstance(msg, list):
                        msg = " ".join(b.get("text", "") for b in msg if isinstance(b, dict))
                    out.append("✗ tool error: " + _clip(msg))
                    thinking = False
        elif t == "result":
            glyph = "✗" if ev.get("is_error") else "✓"
            # Keep the log a tidy event stream: collapse the (often multi-line,
            # markdown) result to a single clipped line. The worker's final
            # message already rendered inline above as a markdown block.
            res = str(ev.get("result", "done")).strip()
            out.append(glyph + " " + _clip(res.splitlines()[0] if res else "done"))
            stats = result_summary(ev)
            if stats:
                out.append(stats)
            thinking = False
    # Surface WHY the output is idle as a trailing status line, even when the log
    # already has content from earlier cycles. idle_reason() is None while a cycle
    # runs or work is queued, so this only fires when genuinely idle — and a stale
    # log from a prior run no longer masks the blocking reason (e.g. a dirty tree
    # holding the queue). "No activity" is the benign empty state; don't spam it.
    if out:
        reason = idle_reason()
        if reason and reason != "No activity":
            out.append("✗ " + reason)
        return out
    return [idle_reason() or "Starting…"]


def read_task(name):
    """Return a task file's text (the plan). Basename-only, no traversal."""
    name = os.path.basename(name or "")
    if not name.endswith(".task.md"):
        return "(invalid task)"
    try:
        with open(os.path.join(REPO, ".mux", "tasks", name)) as f:
            return f.read()
    except OSError:
        return "(task not found)"


def _md_page(title, meta_chips_html, body_md):
    """The shared styled-markdown document used by the drawer (plan + summary):
    dark serif prose via marked.js, with a `.title`/`.meta` header. `title` is
    plain text, `meta_chips_html` is trusted inline HTML, `body_md` is markdown."""
    hjs = json.dumps(f'<div class=title>{escape(title)}</div><div class=meta>{meta_chips_html}</div>').replace("</", "<\\/")
    bjs = json.dumps(body_md).replace("</", "<\\/")
    return f"""<!doctype html><meta charset=utf-8><title>{escape(title)}</title>
<script src="/web/vendor/marked.min.js"></script>
<link rel=stylesheet href="/web/theme.css">
<style>body{{margin:0;background:var(--mux-bg);color:var(--mux-text)}}
 ::selection{{background:var(--mux-select-bg);color:var(--mux-bright)}}
 .md{{box-sizing:border-box;max-width:68ch;margin:0 auto;padding:48px 40px 96px;min-height:100vh;
  font:17px/1.78 Georgia,"Iowan Old Style","Palatino",serif;
  hanging-punctuation:first allow-end;text-rendering:optimizeLegibility}}
 .title{{font:600 23px/1.25 Georgia,"Iowan Old Style","Palatino",serif;color:var(--mux-text-strong);
  letter-spacing:-.01em;text-wrap:balance}}
 .meta{{font:11.5px/1.7 ui-monospace,Menlo,monospace;color:var(--mux-text-muted);margin:7px 0 30px;
  padding-bottom:18px;border-bottom:1px solid var(--mux-border);letter-spacing:.01em}}
 .meta b{{color:var(--mux-text-dim);font-weight:600}}
 .md>:first-child{{margin-top:0}}
 .md h1,.md h2,.md h3,.md h4{{font-family:Georgia,"Iowan Old Style","Palatino",serif;
  color:var(--mux-text-strong);line-height:1.25;margin:1.9em 0 .55em;text-wrap:balance}}
 .md h1{{font-size:26px;letter-spacing:-.015em;margin-top:1.4em}}
 .md h2{{font-size:20px;letter-spacing:-.01em;padding-bottom:.28em;border-bottom:1px solid var(--mux-border-faint)}}
 .md h3{{font-size:17px;font-weight:600;letter-spacing:-.005em}}
 .md h4{{font-size:14px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:var(--mux-text-dim)}}
 .md p{{margin:0 0 1.05em}} .md li{{margin:.3em 0}}
 .md ul,.md ol{{margin:0 0 1.05em;padding-left:1.4em}}
 .md li>ul,.md li>ol{{margin:.3em 0}}
 .md ul{{list-style:none}}
 .md ul>li{{position:relative}}
 .md ul>li::before{{content:"";position:absolute;left:-1em;top:.72em;width:4px;height:4px;
  border-radius:50%;background:var(--mux-dim)}}
 .md ol{{padding-left:1.6em}}
 .md li::marker{{color:var(--mux-text-muted)}}
 .md a{{color:var(--mux-text);text-decoration:none;border-bottom:1px solid var(--mux-border-strong)}}
 .md a:hover{{border-bottom-color:var(--mux-dim)}}
 .md strong{{color:var(--mux-text-strong);font-weight:600}}
 .md em{{color:var(--mux-text-bright)}}
 .md code{{font:13px/1.5 ui-monospace,Menlo,monospace;background:var(--mux-chip);
  border-radius:4px;padding:.12em .42em;color:var(--mux-code-accent)}}
 .md pre{{background:var(--mux-panel);border:1px solid var(--mux-border-faint);border-radius:8px;padding:15px 18px;
  margin:0 0 1.05em;overflow:auto}}
 .md pre code{{background:none;border:0;padding:0;color:var(--mux-text);font-size:13px;line-height:1.65}}
 .md blockquote{{margin:0 0 1.05em;padding:.1em 0 .1em 1.2em;border-left:2px solid var(--mux-border-strong);
  color:var(--mux-text-dim);font-style:italic}}
 .md blockquote p{{margin:0 0 .5em}} .md blockquote :last-child{{margin-bottom:0}}
 .md hr{{border:0;border-top:1px solid var(--mux-border);margin:2.4em 0}}
 .md table{{border-collapse:collapse;width:100%;margin:0 0 1.05em;font-size:15px}}
 .md th,.md td{{padding:7px 14px 7px 0;text-align:left;border-bottom:1px solid var(--mux-border-faint)}}
 .md th{{color:var(--mux-text-dim);font-weight:600;border-bottom:1px solid var(--mux-border-strong)}}
 @media(max-width:760px){{.md{{padding:28px 22px 64px;font-size:16px}}}}</style>
<article class="md" id=md></article>
<script>document.getElementById("md").innerHTML={hjs}+marked.parse({bjs})</script>"""


def plan_page(name):
    """Render a task with marked.js + GitHub theme. The `# Key: value` metadata
    lines become a compact header (not giant H1s); only the body goes to marked."""
    slug = os.path.basename(name or "").replace(".task.md", "") or "task"
    meta, rest = [], []
    for line in read_task(name).splitlines():
        m = re.match(r"# ([\w][\w -]*?):\s*(.*)$", line)
        if m: meta.append((m.group(1), m.group(2)))
        else: rest.append(line)
    title = next((v for k, v in meta if k.lower() == "task"), slug)
    chips = "  ·  ".join(f"<b>{escape(k)}</b> {escape(v)}" for k, v in meta if k.lower() != "task")
    return _md_page(title, chips, "\n".join(rest))


def spawn_channel(name=None):
    """Open a real Terminal.app window running a channel in this repo, focused."""
    name = re.sub(r"[^A-Za-z0-9_-]", "", name or "") or ("p" + time.strftime("%H%M%S"))
    cmd = f'cd {json.dumps(REPO)} && {json.dumps(MUX)} channel {name}'.replace('"', '\\"')
    # Activate FIRST, then `do script` — so the new window is created while
    # Terminal is frontmost and lands on top, instead of activate racing an
    # already-open window. `set frontmost`/index pins the new window itself.
    script = (
        'tell application "Terminal"\n'
        '  activate\n'
        f'  set w to do script "{cmd}"\n'
        '  set index of (first window whose tabs contains w) to 1\n'
        'end tell'
    )
    subprocess.Popen(["osascript", "-e", script])


def spawn_resume(sid):
    """Open a Terminal.app window continuing a stuck task's exact claude session.
    INTERACTIVE — the human drives, so no -p/stream-json/skip-permissions; normal
    permission prompts apply. Returns False if sid is not a valid session id."""
    if not re.fullmatch(r"[0-9a-f-]{36}", sid or ""):
        return False
    cmd = f'cd {json.dumps(REPO)} && claude --resume {sid}'.replace('"', '\\"')
    script = (
        'tell application "Terminal"\n'
        '  activate\n'
        f'  set w to do script "{cmd}"\n'
        '  set index of (first window whose tabs contains w) to 1\n'
        'end tell'
    )
    subprocess.Popen(["osascript", "-e", script])
    return True


def spawn_direct(task_file):
    """Open a Terminal.app window running an interactive CHANNEL-SCOPED planner
    seeded to work on one DRAFT task — matching `mux channel` (NOT a generic
    plan-mode session). INTERACTIVE — the human drives, so no
    -p/stream-json/skip-permissions; normal permission prompts apply. It runs
    with the same scoped permissions as a channel: `--setting-sources user`
    (ignore the target repo's project settings) and an allowedTools list that
    permits writing/editing ONLY under .mux/** — so the directed session can
    read the repo and shape the task but CANNOT silently edit source. The
    CHANNEL system prompt tells it to refine, not execute, the task.

    RESUME vs FRESH: if the task file carries a `# Channel: <uuid>` header (the
    planner session that authored it — see `task_channel`/CHANNEL.md), this
    --resume's THAT exact planning conversation, RE-PASSING the same planner
    permission flags so the resumed session has identical scope to a new
    planner. If no valid channel id is present, it falls back to a fresh
    channel-scoped planner (no --resume). Only `--resume <sid>` differs between
    the two branches; the flag list is shared.

    NOTE: this directed session runs OUTSIDE the headless board — the task stays
    DRAFT and is never auto-claimed or auto-tracked; the operator drives it by
    hand. Returns False if task_file is not a valid existing task basename."""
    name = os.path.basename(task_file or "")
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.task\.md", name):
        return False
    path = os.path.join(REPO, ".mux", "tasks", name)
    if not os.path.exists(path):
        return False
    prompt = (f"Read .mux/tasks/{name}. This is a DRAFT mux task — help me "
              f"refine and shape it (its Goal/Details), don't start working on "
              f"it yet. {name} is the task we're editing.")
    # Read the CHANNEL role prompt the same way mux.sh does: relative to the mux
    # install (this module's dir), NOT the target repo's CWD. Substitute the
    # directed name, mirroring cmd_channel's `sed s/__NAME__/.../`.
    with open(os.path.join(PROMPTS, "CHANNEL.md"), encoding="utf-8") as fh:
        sysprompt = fh.read().replace("__NAME__", "direct")
    # If this DRAFT records the planner session that authored it, resume THAT
    # conversation; same validation regex spawn_resume uses. Otherwise launch a
    # fresh planner.
    sid = ""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"#\s*Channel:\s*(\S+)", line, re.IGNORECASE)
            if m:
                sid = m.group(1)
                break
    resume = f'--resume {sid} ' if re.fullmatch(r"[0-9a-f-]{36}", sid) else ''
    # Per-session scoped permissions, identical to `mux channel`: ignore project
    # settings (--setting-sources user) and pre-approve writes ONLY under .mux,
    # so a stray source edit can't happen silently. Pattern is .mux/** with NO
    # leading ./ — Claude Code normalizes paths to project-root-relative.
    # ensure_ascii=False keeps non-ASCII (e.g. the em-dash in `prompt`/sysprompt)
    # as literal UTF-8; the default would emit a `—` escape, which AppleScript
    # can't parse ("Expected \" but found unknown token") once embedded in the
    # `do script` string.
    cmd = (f'cd {json.dumps(REPO)} && claude '
           f'{resume}'
           f'--setting-sources user '
           f'--permission-mode default '
           f"--allowedTools 'Read' 'Glob' 'Grep' 'Bash' 'Write(.mux/**)' 'Edit(.mux/**)' "
           f'--append-system-prompt {json.dumps(sysprompt, ensure_ascii=False)} '
           f'{json.dumps(prompt, ensure_ascii=False)}').replace('"', '\\"')
    script = (
        'tell application "Terminal"\n'
        '  activate\n'
        f'  set w to do script "{cmd}"\n'
        '  set index of (first window whose tabs contains w) to 1\n'
        'end tell'
    )
    subprocess.Popen(["osascript", "-e", script])
    return True


def _read_web(*parts):
    """Read a file under mux/web/ relative to THIS module (not the caller's
    CWD — mux runs from inside arbitrary target repos), as text."""
    with open(os.path.join(WEB, *parts), encoding="utf-8") as fh:
        return fh.read()


# The front-end lives in mux/web/index.html (real HTML/CSS/JS, editable as
# such); do_GET reads it FRESH on every "/" request and substitutes the
# provider theme placeholders. It is read per-request (not cached at import)
# on purpose: the output rewrites index.html as it works, so a cached copy
# would serve a stale UI until the server is restarted.


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
        # Never let the browser cache the UI or its data: the output rewrites
        # index.html on nearly every task, and /api/* changes constantly, so a
        # cached copy means a stale page (e.g. an old esc()/log renderer running
        # against fresh data). no-store forces a fresh fetch every load.
        self.send_header("cache-control", "no-store")
        try:
            self.end_headers()
            self.wfile.write(b)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client navigated away / cancelled a poll before we finished — harmless

    def _body(self):
        n = int(self.headers.get("content-length", 0))
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return {}

    def do_GET(self):
        if self.path == "/":
            t = theme()
            page = (_read_web("index.html")
                        .replace("__ACCENT__", t["accent"])
                        .replace("__OK__", t["success"])
                        .replace("__SUB__", t["subagent"])
                        .replace("__DANGER__", t["danger"])
                        .replace("__PROVIDER__", escape(t["label"])))
            self._send(200, page, "text/html; charset=utf-8")
        elif self.path == "/api/tasks":
            if auto_enabled():
                autopilot()          # auto-approve a finished task, BEFORE the board
            self._send(200, json.dumps(tasks()))
        elif self.path == "/api/auto":
            self._send(200, json.dumps({"enabled": auto_enabled()}))
        elif self.path == "/api/log":
            self._send(200, json.dumps(log_lines()))
        elif self.path == "/api/repo":
            self._send(200, json.dumps({"repo": REPO}))
        elif self.path == "/api/status":
            self._send(200, json.dumps(status()))
        elif self.path.startswith("/plan?"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, plan_page(q.get("file", [""])[0]), "text/html; charset=utf-8")
        elif self.path.startswith("/web/"):
            # Serve files under mux/web/ (e.g. vendor/marked.min.js), resolved
            # against WEB and confined to it — normpath collapses any ../ so a
            # request can't escape the web dir.
            rel = urllib.parse.unquote(self.path[len("/web/"):].split("?")[0])
            full = os.path.normpath(os.path.join(WEB, rel))
            if full != WEB and not full.startswith(WEB + os.sep):
                self._send(404, "not found", "text/plain")
                return
            ctype = "text/css" if full.endswith(".css") else "application/javascript"
            try:
                with open(full, "rb") as fh:
                    self._send(200, fh.read(), ctype)
            except OSError:
                self._send(404, "not found", "text/plain")
        else:
            self._send(404, "{}")

    def do_POST(self):
        d = self._body()
        if self.path == "/api/verb":
            args = [d["verb"]]
            if d.get("id"):   args.append(d["id"])
            if d.get("text"): args.append(d["text"])
            ok, out = mux(*args)
            self._send(200, json.dumps({"ok": ok, "out": out}))
        elif self.path == "/api/auto":
            path = os.path.join(REPO, ".mux", "auto")
            if d.get("enabled"):
                open(path, "w").close()      # presence = ON
            elif os.path.exists(path):
                os.remove(path)              # absence = OFF
            self._send(200, json.dumps({"enabled": auto_enabled()}))
        elif self.path == "/api/channel":
            spawn_channel(d.get("name"))
            self._send(200, json.dumps({"ok": True}))
        elif self.path == "/api/resume":
            ok = spawn_resume(d.get("id"))
            self._send(200 if ok else 400,
                       json.dumps({"ok": ok, "out": "" if ok else "invalid session id"}))
        elif self.path == "/api/direct":
            ok = spawn_direct(d.get("file"))
            self._send(200 if ok else 400,
                       json.dumps({"ok": ok, "out": "" if ok else "invalid task file"}))
        else:
            self._send(404, "{}")

    def log_message(self, *a):
        pass  # quiet


if __name__ == "__main__":
    # When launched via `mux web` the launcher already prints the URL; only
    # announce here if run standalone.
    if not os.environ.get("MUX_BIN"):
        print(f"mux web → http://127.0.0.1:{PORT}   (repo: {REPO})")
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()

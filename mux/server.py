#!/usr/bin/env python3
"""mux web — a tiny local UI over the mux queue. Python stdlib only, no deps.

Launched in a repo via `mux web`; serves that repo's .mux/ queue at
http://127.0.0.1:<port>. Three things, nothing to memorize:
  • watch the headless executor's live log  (read-only — it cannot be reprompted)
  • see the task list, and act with buttons  (release / approve / answer / fail)
  • a button to open a planner in a real terminal

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

# Provider→theme map: the UI accent + header label come from ONE place here, so
# re-skinning for a different executor backend = changing/adding one entry and
# setting MUX_PROVIDER. Unknown providers fall back to the neutral "generic".
THEMES = {
    "claude": {"accent": "#d97757", "label": "Claude"},
    "openai": {"accent": "#10a37f", "label": "OpenAI"},
    "gemini": {"accent": "#4285f4", "label": "Gemini"},
    "generic": {"accent": "#8a8072", "label": "Executor"},
}

def theme():
    """The active provider's theme (accent + label), from MUX_PROVIDER."""
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
    """True if the tree has changes OUTSIDE .mux/ — exactly what blocks the executor
    (mirrors mux.sh git_clean: the .mux/ queue is metadata, never counts as work)."""
    r = subprocess.run(["git", "status", "--porcelain"], cwd=REPO,
                       capture_output=True, text=True)
    for line in r.stdout.splitlines():
        path = line[3:]
        if path and not (path == ".mux" or path.startswith(".mux/")):
            return True
    return False


def auto_enabled():
    """True when auto mode is ON — persisted as the EXISTENCE of .mux/auto (on
    disk so it survives restart, inside .mux/ so it never counts as work)."""
    return os.path.exists(os.path.join(REPO, ".mux", "auto"))


def autopilot():
    """One hands-off cycle, piggy-backed on the /api/tasks poll when auto is ON.
    Flips ONLY the two human gates — release (in bulk) then approve — never
    auto-claims, reverts, fails, or resolves. Order matters: release first.

    Auto-approve fires only when a finished RUNNING task is genuinely waiting:
    it exists, its tick is NOT in flight, it is not flagged interrupted, and the
    tree is dirty outside .mux/ (real work to commit). Any miss → do nothing
    this cycle (never `mux ok` a clean tree — it would die — or a live tick)."""
    mux("release-all")
    if status()["executing"]:
        return
    ts = tasks()
    running = next((t for t in ts if t.get("status") == "RUNNING"), None)
    if running and not running.get("interrupted") and git_dirty_nonmux():
        mux("ok")


def idle_reason():
    """Why is nothing running right now? None when the executor has/holds work
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
                    "Approve or revert it to free the executor.")
        if ready:
            return ("Idle — the working tree has uncommitted changes outside .mux/. "
                    "The executor only runs from a clean tree — commit or stash them to start.")
        return "Idle — uncommitted changes outside .mux/."
    if ready:
        return "Idle — the next task is waiting on a dependency."
    return "No activity"


def status():
    """Live executor state for the page's working indicator.
    executing = a tick is in flight (.mux/tick.lock exists); elapsed = seconds
    since the lock dir was created (its mtime), or None if unreadable/idle."""
    lock = os.path.join(REPO, ".mux", "tick.lock")
    if not os.path.isdir(lock):
        return {"executing": False, "elapsed": None}
    try:
        elapsed = int(time.time() - os.path.getmtime(lock))
    except OSError:
        elapsed = None
    return {"executing": True, "elapsed": elapsed}


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
    if ev.get("total_cost_usd") is not None:
        segs.append(f"${float(ev['total_cost_usd']):.4g}")
    return "Σ " + " · ".join(segs) if segs else ""


def log_lines(limit=300):
    """Render the latest tick log (Claude stream-json) into readable lines."""
    path = os.path.join(REPO, ".mux", "log", "executor.jsonl")
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
                out.append(f"─────────── cycle {cycle} ───────────")
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
                    out.append("● " + blk["text"].strip())
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
            # markdown) result to a single clipped line. The full formatted text
            # lives in the drawer via `summary_page()`.
            res = str(ev.get("result", "done")).strip()
            out.append(glyph + " " + _clip(res.splitlines()[0] if res else "done"))
            stats = result_summary(ev)
            if stats:
                out.append(stats)
            thinking = False
    return out or [idle_reason() or "Starting…"]


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
    acc = theme()["accent"]   # link color follows the active provider accent
    return f"""<!doctype html><meta charset=utf-8><title>{escape(title)}</title>
<script src="/web/marked.min.js"></script>
<style>body{{margin:0;background:#1a1815;color:#dcd6ca}}
 ::selection{{background:#3a2d24;color:#f0ebe0}}
 .md{{box-sizing:border-box;max-width:68ch;margin:0 auto;padding:48px 40px 96px;min-height:100vh;
  font:17px/1.78 Georgia,"Iowan Old Style","Palatino",serif;
  hanging-punctuation:first allow-end;text-rendering:optimizeLegibility}}
 .title{{font:600 23px/1.25 Georgia,"Iowan Old Style","Palatino",serif;color:#f3eee4;
  letter-spacing:-.01em;text-wrap:balance}}
 .meta{{font:11.5px/1.7 ui-monospace,Menlo,monospace;color:#807767;margin:7px 0 30px;
  padding-bottom:18px;border-bottom:1px solid #2a2620;letter-spacing:.01em}}
 .meta b{{color:#a89e8e;font-weight:600}}
 .md>:first-child{{margin-top:0}}
 .md h1,.md h2,.md h3,.md h4{{font-family:Georgia,"Iowan Old Style","Palatino",serif;
  color:#f3eee4;line-height:1.25;margin:1.9em 0 .55em;text-wrap:balance}}
 .md h1{{font-size:26px;letter-spacing:-.015em;margin-top:1.4em}}
 .md h2{{font-size:20px;letter-spacing:-.01em;padding-bottom:.28em;border-bottom:1px solid #262219}}
 .md h3{{font-size:17px;font-weight:600;letter-spacing:-.005em}}
 .md h4{{font-size:14px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:#a89e8e}}
 .md p{{margin:0 0 1.05em}} .md li{{margin:.3em 0}}
 .md ul,.md ol{{margin:0 0 1.05em;padding-left:1.4em}}
 .md li>ul,.md li>ol{{margin:.3em 0}}
 .md ul{{list-style:none}}
 .md ul>li{{position:relative}}
 .md ul>li::before{{content:"";position:absolute;left:-1em;top:.72em;width:4px;height:4px;
  border-radius:50%;background:#6e6555}}
 .md ol{{padding-left:1.6em}}
 .md li::marker{{color:#807767}}
 .md a{{color:{acc};text-decoration:none;border-bottom:1px solid #5c3e30}}
 .md a:hover{{border-bottom-color:{acc}}}
 .md strong{{color:#f3eee4;font-weight:600}}
 .md em{{color:#e6e0d4}}
 .md code{{font:13px/1.5 ui-monospace,Menlo,monospace;background:#211d18;
  border-radius:4px;padding:.12em .42em;color:#dcb992}}
 .md pre{{background:#100e0b;border:1px solid #262219;border-radius:8px;padding:15px 18px;
  margin:0 0 1.05em;overflow:auto}}
 .md pre code{{background:none;border:0;padding:0;color:#cfc9bc;font-size:13px;line-height:1.65}}
 .md blockquote{{margin:0 0 1.05em;padding:.1em 0 .1em 1.2em;border-left:2px solid #3a342c;
  color:#a89e8e;font-style:italic}}
 .md blockquote p{{margin:0 0 .5em}} .md blockquote :last-child{{margin-bottom:0}}
 .md hr{{border:0;border-top:1px solid #2a2620;margin:2.4em 0}}
 .md table{{border-collapse:collapse;width:100%;margin:0 0 1.05em;font-size:15px}}
 .md th,.md td{{padding:7px 14px 7px 0;text-align:left;border-bottom:1px solid #262219}}
 .md th{{color:#a89e8e;font-weight:600;border-bottom:1px solid #3a342c}}
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


def latest_summary():
    """Return (markdown_text, meta_chips_html) for the most recent executor
    `result` event in executor.jsonl — the final assistant summary, plus its
    `Σ …` cost/turn stats as a meta line. Parse defensively (skip undecodable
    lines like `log_lines()` does); return a placeholder when the file is
    missing/unreadable or holds no `result` event."""
    path = os.path.join(REPO, ".mux", "log", "executor.jsonl")
    last = None
    try:
        with open(path) as f:
            for line in f:
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if ev.get("type") == "result":
                    last = ev
    except OSError:
        return "(no executor summary yet)", ""
    if last is None:
        return "(no executor summary yet)", ""
    text = str(last.get("result", "")).strip() or "(no executor summary yet)"
    return text, escape(result_summary(last))


def summary_page():
    """Render the latest executor summary through the shared markdown drawer page."""
    text, meta = latest_summary()
    return _md_page("Executor summary", meta, text)


def spawn_planner(name=None):
    """Open a real Terminal.app window running a planner in this repo, focused."""
    name = re.sub(r"[^A-Za-z0-9_-]", "", name or "") or ("p" + time.strftime("%H%M%S"))
    cmd = f'cd {json.dumps(REPO)} && {json.dumps(MUX)} planner {name}'.replace('"', '\\"')
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


PAGE = """<!doctype html><meta charset=utf-8><title>mux</title>
<style>
 :root{--accent:__ACCENT__}
 body{margin:0;font:14px/1.5 ui-monospace,Menlo,monospace;background:#1a1815;color:#e3ddd1}
 header{padding:10px 16px;background:#1a1815;border-bottom:1px solid #2a2620;display:flex;gap:12px;align-items:center}
 header b{color:#ffffff;font-weight:600} header .sp{flex:1} button{font:inherit;cursor:pointer;border:1px solid #2a2620;
  background:transparent;color:#a89e8e;border-radius:4px;padding:3px 9px} button:hover{border-color:var(--accent);color:#e3ddd1}
 #counts,#provider{color:#8a8072;font-size:12px;white-space:nowrap} #counts .sep{color:#3a342c;margin:0 5px}
 /* Resizable split: a draggable #splitter sits between the two sections as a
    grid column; --split (a %) drives the Tasks column, 1fr fills the rest. */
 main{display:grid;grid-template-columns:var(--split,40%) 6px 1fr;background:#2a2620;height:calc(100vh - 49px)}
 #splitter{background:#2a2620;cursor:col-resize}
 #splitter:hover,body.dragging #splitter{background:var(--accent)}
 body.dragging{user-select:none}
 /* Narrow viewport: stack Tasks above Executor and let the page scroll
    instead of squeezing two columns. Hide the splitter (no col-resize when
    stacked) and drop the fixed viewport height so the sections flow. */
 @media(max-width:720px){
  main{grid-template-columns:1fr;height:auto}
  #splitter{display:none}
  section{min-height:50vh}
 }
 section{background:#1a1815;overflow:auto;padding:12px 16px} .t{padding:7px 0;border-bottom:1px solid #221f1a}
 .t .st{font-size:11px;letter-spacing:.04em;text-transform:lowercase;color:#8a8072}
 .RUNNING{color:var(--accent)}.FAILED{color:#c5836b}.BLOCKED{color:#c5836b}
 .READY,.DONE,.DRAFT{color:#8a8072} .t .nm{color:#d8d2c6;margin:2px 0;cursor:pointer}
 button.danger{color:#8a8072} button.danger:hover{border-color:#c5836b;color:#c5836b}
 #autobtn.on{border-color:var(--accent);color:var(--accent)}
 .run{display:inline-flex;align-items:center;gap:8px;color:var(--accent);font-size:12px}
 .shimmer{background:linear-gradient(90deg,#6b5f50 0%,#b09a82 20%,#e8a888 50%,#b09a82 80%,#6b5f50 100%);background-size:200% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;-webkit-text-fill-color:transparent;animation:shimmer 1.6s linear infinite}
 @keyframes shimmer{from{background-position:200% 0}to{background-position:-200% 0}}
 .plan{margin:6px 0 0;padding:8px 10px;background:#13110e;border-radius:6px;color:#a89e8e;font-size:12px;white-space:pre-wrap;max-height:260px;overflow:auto}
 .acts{margin-top:6px;display:flex;gap:6px;flex-wrap:wrap}
 #summarybar{margin:0 0 10px}
 #summarybar .slink{cursor:pointer;font-size:12px;color:#8a8072}
 #summarybar .slink:hover{color:#e3ddd1}
 #nowrunning:empty{display:none}
 #nowrunning .pill{display:inline-block;cursor:pointer;font-size:12px;color:var(--accent);margin:0 0 10px}
 #nowrunning .pill:hover{color:#e3ddd1}
 #working{font:12.5px/1.55 ui-monospace,Menlo,monospace;margin:0 0 8px;min-height:0}
 #working:empty{margin:0}
 #working .glyph{display:inline-block;animation:spin 1.1s steps(8) infinite;margin-right:6px}
 @keyframes spin{from{transform:rotate(0)}to{transform:rotate(360deg)}}
 #log{margin:0;font:12.5px/1.55 ui-monospace,Menlo,monospace;white-space:pre-wrap;word-break:break-word}
 #log .l{padding:1px 0} .la{color:#ece6da} .lt{color:#c98c6d} .lr{color:#6fae7a} .ls{color:#3a342c;margin:8px 0} .lx{color:#a89e8e} .lg{color:#b292c4} .le{color:#d6705f} .lm{color:#a89e8e}
 #backdrop{position:fixed;inset:0;background:rgba(10,8,6,.55);opacity:0;pointer-events:none;transition:opacity .2s ease;z-index:40}
 #drawer{position:fixed;top:0;right:0;height:100vh;width:min(720px,92vw);background:#1a1815;border-left:1px solid #2a2620;
  display:flex;flex-direction:column;transform:translateX(100%);transition:transform .2s ease;z-index:41;box-shadow:-12px 0 30px rgba(0,0,0,.4)}
 body.drawer-open #backdrop{opacity:1;pointer-events:auto}
 body.drawer-open #drawer{transform:translateX(0)}
 #drawer .dhead{display:flex;align-items:center;justify-content:flex-end;padding:6px 10px;border-bottom:1px solid #2a2620;background:#0c0f13}
 #drawer .dclose{font:inherit;cursor:pointer;border:1px solid #3a342c;background:#241f1a;color:#d6dde6;border-radius:6px;padding:1px 9px;line-height:1.4}
 #drawer .dclose:hover{border-color:var(--accent)}
 #drawer iframe{flex:1;width:100%;border:0;background:#1a1815}
</style>
<header><b>MULTIPLEXER</b><span id=provider>__PROVIDER__</span><span id=repo></span><span class=sp></span><span id=counts></span>
 <button id=autobtn onclick="toggleAuto()" title="Auto mode: auto-release every DRAFT and auto-approve finished tasks">Auto mode: …</button>
 <button onclick="planner()">+ planner</button></header>
<main>
 <section><div id=tasks></div></section>
 <div id=splitter></div>
 <section><div id=summarybar><span class=slink onclick="openSummary()" title="open the executor's latest summary">📄 summary</span></div><div id=nowrunning></div><div id=working></div><pre id=log></pre></section>
</main>
<div id=backdrop onclick="closePlan()"></div>
<div id=drawer><div class=dhead><button class=dclose onclick="closePlan()" title="close">×</button></div><iframe id=planframe></iframe></div>
<script>
const E=(s)=>document.getElementById(s)
const esc=s=>s.replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]))
// Draggable splitter: --split is the Tasks-column width as a %, clamped 20-80%,
// persisted in localStorage (mux.split). Absent -> CSS default of 40%.
(function(){const saved=localStorage.getItem("mux.split")
 if(saved)document.documentElement.style.setProperty("--split",saved+"%")
 const sp=E("splitter"),main=document.querySelector("main")
 sp.addEventListener("pointerdown",e=>{e.preventDefault();sp.setPointerCapture(e.pointerId)
  document.body.classList.add("dragging")
  const move=ev=>{const r=main.getBoundingClientRect()
   let pct=(ev.clientX-r.left)/r.width*100
   pct=Math.max(20,Math.min(80,pct))
   document.documentElement.style.setProperty("--split",pct+"%")
   localStorage.setItem("mux.split",pct.toFixed(2))}
  const up=()=>{document.body.classList.remove("dragging")
   sp.removeEventListener("pointermove",move);sp.removeEventListener("pointerup",up)}
  sp.addEventListener("pointermove",move);sp.addEventListener("pointerup",up)})
})()
function openPlan(file){E("planframe").src='/plan?file='+encodeURIComponent(file);document.body.classList.add("drawer-open")}
function openSummary(){E("planframe").src='/summary';document.body.classList.add("drawer-open")}
function closePlan(){document.body.classList.remove("drawer-open");E("planframe").src="about:blank"}
document.addEventListener("keydown",e=>{if(e.key=="Escape")closePlan()})
// Working indicator: server says executing/elapsed (polled in refresh); the
// counter is driven client-side from a start time so it ticks every second
// without hammering the server. work.start=null means no cycle in flight.
let work={start:null,known:false}
function drawWork(){const w=E("working");if(!w)return
 if(work.start===null){w.innerHTML="";return}
 const secs=work.known?Math.max(0,Math.floor((Date.now()-work.start)/1000)):null
 w.innerHTML='<span class=glyph>✳</span><span class=shimmer>Working…'+(secs===null?"":" "+secs+"s")+'</span>'}
async function pollStatus(){try{const s=await (await fetch("/api/status")).json()
  if(!s.executing){work.start=null;work.known=false}
  else{const base=Date.now()-(s.elapsed||0)*1000
   // Re-sync start only on a new cycle or first sight, so the local counter
   // stays smooth instead of jumping each poll.
   if(work.start===null||Math.abs(base-work.start)>3000)work.start=base
   work.known=s.elapsed!=null}}
 catch(e){}
 drawWork()}
async function act(verb,id,prompt){let text=""
 if(prompt){text=window.prompt(prompt);if(text===null)return}
 try{const r=await fetch("/api/verb",{method:"POST",headers:{"content-type":"application/json"},
   body:JSON.stringify({verb,id,text})})
  const d=await r.json()
  if(!d.ok)alert("mux "+verb+" failed:\\n"+(d.out||("HTTP "+r.status)))}
 catch(e){alert("request failed: "+e)}
 refresh()}
function planner(){fetch("/api/planner",{method:"POST",headers:{"content-type":"application/json"},body:"{}"})
 .catch(e=>alert("planner failed: "+e))}
// Open a Terminal continuing a stuck task's exact claude session (human-driven).
function resume(id){fetch("/api/resume",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({id})})
 .then(r=>r.json()).then(d=>{if(!d.ok)alert("resume failed:\\n"+(d.out||""))}).catch(e=>alert("resume failed: "+e))}
// Auto mode (persisted server-side). When ON the toggle does the Release/Approve
// gates' job, so those per-task buttons are hidden; revert/answer escape hatches stay.
let auto=false
function drawAuto(){const b=E("autobtn");if(!b)return
 b.textContent="Auto mode: "+(auto?"on":"off");b.classList.toggle("on",auto)}
async function toggleAuto(){try{const r=await fetch("/api/auto",{method:"POST",
   headers:{"content-type":"application/json"},body:JSON.stringify({enabled:!auto})})
  auto=(await r.json()).enabled}catch(e){alert("auto toggle failed: "+e)}
 drawAuto();refresh()}
function buttons(t){const b=[],f=t.file
 // Resume only for stuck tasks (BLOCKED, or RUNNING killed mid-tick) — never a
 // normally executing task: a second claude would collide with the live tick.
 if(t.session&&(t.awaiting_answer||t.interrupted))
  b.push(`<button onclick="resume('${t.session}')">resume ⇥</button>`)
 if(t.status=="DRAFT"&&!auto)b.push(`<button onclick="act('release','${f}')">Release</button>`)
 if(t.status=="RUNNING"){
  if(t.executing)return ""
  if(!auto)b.push(`<button onclick="act('ok')">Approve</button>`)
  b.push(`<button class=danger onclick="if(confirm('Discard this task\\'s changes?'))act('revert')">revert</button>`)}
 if(t.status=="BLOCKED")b.push(`<button onclick="act('resolve','${f}','your answer')">answer</button>`)
 return `<div class=acts>${b.join("")}</div>`}
async function refresh(){
 const ts=await (await fetch("/api/tasks")).json()
 const rank=s=>s=="DONE"?1:0; ts.sort((a,b)=>rank(a.status)-rank(b.status))
 E("tasks").innerHTML=ts.map(t=>`<div class=t><div class="st ${t.status}">${t.status}`+
  `${t.current?" ·current":""}${t.next?" ·next":""}${t.awaiting_answer?" ·awaiting you":""}`+
  `${t.dep_status=="pending"?" ·blocked by dep":""}</div>`+
  `<div class=nm onclick="openPlan('${t.file}')" title="open plan"><span class="${t.executing?'shimmer':''}">${t.file.replace(/\\.task\\.md$/,"")}</span></div>`+
  `${buttons(t)}</div>`).join("")||"<div style='color:#8a8072;font-size:12.5px'>No tasks</div>"
 const order=["RUNNING","READY","BLOCKED","DRAFT","FAILED","DONE"]
 const by={};ts.forEach(t=>by[t.status]=(by[t.status]||0)+1)
 E("counts").innerHTML=order.filter(s=>by[s]).map(s=>`<span class=${s}>${by[s]} ${s.toLowerCase()}</span>`).join("<span class=sep>·</span>")
 const nowt=ts.find(t=>t.executing)||ts.find(t=>t.current&&t.status=="RUNNING")
 E("nowrunning").innerHTML=nowt?`<span class=pill onclick="openPlan('${nowt.file}')" title="open plan">${nowt.file.replace(/\\.task\\.md$/,"")}</span>`:""
 const lg=await (await fetch("/api/log")).json()
 E("log").innerHTML=lg.slice().reverse().map(l=>{const c={"●":"la","→":"lt","✓":"lr","─":"ls","⌖":"lg","✗":"le","Σ":"lm"}[l[0]]||"lx";return `<div class="l ${c}">${esc(l)}</div>`}).join("")||((nowt||E("working").innerHTML)?"":"<div style='color:#8a8072;font-size:12.5px'>Idle — waiting for a READY task</div>")
 pollStatus()}
fetch("/api/repo").then(r=>r.json()).then(d=>E("repo").textContent=d.repo)
fetch("/api/auto").then(r=>r.json()).then(d=>{auto=d.enabled;drawAuto();refresh()})
refresh();setInterval(refresh,2000);setInterval(drawWork,1000)
</script>"""


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
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
            page = PAGE.replace("__ACCENT__", t["accent"]).replace("__PROVIDER__", escape(t["label"]))
            self._send(200, page, "text/html; charset=utf-8")
        elif self.path == "/api/tasks":
            if auto_enabled():
                autopilot()          # release-all then (if safe) ok, BEFORE the board
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
        elif self.path == "/summary":
            self._send(200, summary_page(), "text/html; charset=utf-8")
        elif self.path.startswith("/web/"):
            name = os.path.basename(self.path.split("?")[0])
            ctype = "text/css" if name.endswith(".css") else "application/javascript"
            try:
                with open(os.path.join(WEB, name), "rb") as fh:
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
        elif self.path == "/api/planner":
            spawn_planner(d.get("name"))
            self._send(200, json.dumps({"ok": True}))
        elif self.path == "/api/resume":
            ok = spawn_resume(d.get("id"))
            self._send(200 if ok else 400,
                       json.dumps({"ok": ok, "out": "" if ok else "invalid session id"}))
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

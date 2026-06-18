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
<script src="/web/vendor/marked.min.js"></script>
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


def _read_web(*parts):
    """Read a file under mux/web/ relative to THIS module (not the caller's
    CWD — mux runs from inside arbitrary target repos), as text."""
    with open(os.path.join(WEB, *parts), encoding="utf-8") as fh:
        return fh.read()


# The front-end lives in mux/web/index.html (real HTML/CSS/JS, editable as
# such); the server reads it at import time and substitutes the provider
# theme placeholders per request in do_GET.
PAGE = _read_web("index.html")


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

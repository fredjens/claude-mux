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
    d = " ".join(str(d).split())
    if len(d) > 90:
        d = d[:88] + "…"
    return f"→ {name}: {d}" if d else f"→ {name}"


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
            # any other system subtype: ignore (no divider, no crash)
        elif t == "assistant":
            for blk in ev.get("message", {}).get("content", []):
                if blk.get("type") == "text" and blk.get("text", "").strip():
                    out.append("● " + blk["text"].strip())
                    thinking = False
                elif blk.get("type") == "tool_use":
                    out.append(tool_line(blk))
                    thinking = False
        elif t == "result":
            out.append("✓ " + str(ev.get("result", "done")).strip())
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
    hjs = json.dumps(f'<div class=title>{escape(title)}</div><div class=meta>{chips}</div>').replace("</", "<\\/")
    bjs = json.dumps("\n".join(rest)).replace("</", "<\\/")
    return f"""<!doctype html><meta charset=utf-8><title>{escape(title)}</title>
<link rel=stylesheet href="/web/github-markdown.min.css">
<script src="/web/marked.min.js"></script>
<style>body{{margin:0;color-scheme:light dark;background:#fff}}
 @media(prefers-color-scheme:dark){{body{{background:#0d1117}}}}
 .markdown-body{{box-sizing:border-box;max-width:1080px;margin:0 auto;padding:34px 44px;min-height:100vh}}
 .title{{font-size:20px;font-weight:700}} .meta{{font:12px/1.7 ui-monospace,Menlo,monospace;color:#8a98a8;margin:3px 0 12px}}
 @media(max-width:760px){{.markdown-body{{padding:18px}}}}</style>
<article class="markdown-body" id=md></article>
<script>document.getElementById("md").innerHTML={hjs}+marked.parse({bjs})</script>"""


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


PAGE = """<!doctype html><meta charset=utf-8><title>mux</title>
<style>
 body{margin:0;font:14px/1.5 ui-monospace,Menlo,monospace;background:#11151a;color:#d6dde6}
 header{padding:10px 16px;background:#0c0f13;border-bottom:1px solid #222;display:flex;gap:12px;align-items:center}
 header b{color:#fff} header .sp{flex:1} button{font:inherit;cursor:pointer;border:1px solid #2c3742;
  background:#1a212a;color:#d6dde6;border-radius:6px;padding:3px 9px} button:hover{border-color:#3d72d6}
 main{display:grid;grid-template-columns:1fr 1fr;gap:1px;background:#222;height:calc(100vh - 49px)}
 section{background:#11151a;overflow:auto;padding:12px 16px} h2{font-size:12px;letter-spacing:.08em;
  text-transform:uppercase;color:#7c8a99;margin:0 0 10px} .t{padding:8px 10px;border:1px solid #222;
  border-radius:8px;margin-bottom:8px} .t .st{font-size:11px;font-weight:700;letter-spacing:.05em}
 .RUNNING{color:#e0a33e}.READY{color:#3d72d6}.DONE{color:#3da35d}.FAILED{color:#d65a5a}
 .BLOCKED{color:#c678dd}.DRAFT{color:#7c8a99} .t .nm{color:#cdd6df;margin:2px 0;cursor:pointer} .open{color:#56708f}
 button.danger{border-color:#5a3030;color:#d99} button.danger:hover{border-color:#d65a5a}
 .run{display:inline-flex;align-items:center;gap:8px;color:#e0a33e;font-size:12px}
 .shimmer{background:linear-gradient(90deg,#a8741f 0%,#cdd6df 20%,#fff6e6 50%,#cdd6df 80%,#a8741f 100%);background-size:200% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;-webkit-text-fill-color:transparent;animation:shimmer 1.6s linear infinite}
 @keyframes shimmer{from{background-position:200% 0}to{background-position:-200% 0}}
 .plan{margin:6px 0 0;padding:8px 10px;background:#0c0f13;border-radius:6px;color:#9fb0c0;font-size:12px;white-space:pre-wrap;max-height:260px;overflow:auto}
 .acts{margin-top:6px;display:flex;gap:6px;flex-wrap:wrap}
 #log{margin:0;font:12.5px/1.55 ui-monospace,Menlo,monospace;white-space:pre-wrap;word-break:break-word}
 #log .l{padding:1px 0} .la{color:#e6edf3} .lt{color:#56b6c2} .lr{color:#5bb574} .ls{color:#3f4855;margin:8px 0} .lx{color:#9aa7b4}
</style>
<header><b>CLAUDE MULTIPLEXER</b><span id=repo></span><span class=sp></span>
 <button onclick="planner()">+ planner</button></header>
<main>
 <section><h2>Tasks</h2><div id=tasks></div></section>
 <section><h2>Executor</h2><pre id=log></pre></section>
</main>
<script>
const E=(s)=>document.getElementById(s)
const esc=s=>s.replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]))
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
function buttons(t){const b=[],f=t.file
 if(t.status=="DRAFT")b.push(`<button onclick="act('release','${f}')">Approve</button>`)
 if(t.status=="RUNNING"){
  if(t.executing)return `<div class=acts><span class=run>working…</span></div>`
  b.push(`<button onclick="act('ok')">approve</button>`)
  b.push(`<button class=danger onclick="if(confirm('Discard this task\\'s changes?'))act('revert')">revert</button>`)}
 if(t.status=="BLOCKED")b.push(`<button onclick="act('resolve','${f}','your answer')">answer</button>`)
 return `<div class=acts>${b.join("")}</div>`}
async function refresh(){
 const ts=await (await fetch("/api/tasks")).json()
 E("tasks").innerHTML=ts.map(t=>`<div class=t><div class="st ${t.status}">${t.status}`+
  `${t.current?" ·current":""}${t.next?" ·next":""}${t.awaiting_answer?" ·awaiting you":""}`+
  `${t.dep_status=="pending"?" ·blocked by dep":""}</div>`+
  `<div class=nm onclick="window.open('/plan?file='+encodeURIComponent('${t.file}'),'_blank')" title="open plan"><span class="${t.executing?'shimmer':''}">${t.file.replace(/\\.task\\.md$/,"")}</span> <span class=open>↗</span></div>`+
  `${buttons(t)}</div>`).join("")||"<div style='color:#9aa7b4;font-size:12.5px'>No tasks</div>"
 const lg=await (await fetch("/api/log")).json()
 E("log").innerHTML=lg.slice().reverse().map(l=>{const c={"●":"la","→":"lt","✓":"lr","─":"ls"}[l[0]]||"lx";return `<div class="l ${c}">${esc(l)}</div>`}).join("")}
fetch("/api/repo").then(r=>r.json()).then(d=>E("repo").textContent=d.repo)
refresh();setInterval(refresh,2000)
</script>"""


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get("content-length", 0))
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return {}

    def do_GET(self):
        if self.path == "/":
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif self.path == "/api/tasks":
            self._send(200, json.dumps(tasks()))
        elif self.path == "/api/log":
            self._send(200, json.dumps(log_lines()))
        elif self.path == "/api/repo":
            self._send(200, json.dumps({"repo": REPO}))
        elif self.path.startswith("/plan?"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, plan_page(q.get("file", [""])[0]), "text/html; charset=utf-8")
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
        elif self.path == "/api/planner":
            spawn_planner(d.get("name"))
            self._send(200, json.dumps({"ok": True}))
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

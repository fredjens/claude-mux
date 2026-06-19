#!/usr/bin/env python3
"""Dependency-free unittest suite for mux/server.py (stdlib only).

Run:  python3 mux/tests/test_server.py
  or: python3 -m unittest mux.tests.test_server

server.py reads REPO/MUX/PORT from env into module globals at import time. We
import it ONCE by file path (so we don't need an __init__.py in mux/), then per
test override server.REPO and monkeypatch server.mux/server.tasks/idle_reason,
restoring everything in tearDown.
"""
import importlib.util
import json
import os
import tempfile
import threading
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer

# --- load server.py by path (no package import, no __init__.py needed) --------
_SERVER_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server.py")
_spec = importlib.util.spec_from_file_location("mux_server_under_test", _SERVER_PATH)
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)


class ToolLineTest(unittest.TestCase):
    def test_bash_shows_command(self):
        self.assertEqual(
            server.tool_line({"name": "Bash", "input": {"command": "ls -la"}}),
            "→ Bash: ls -la",
        )

    def test_file_tools_show_basename(self):
        for name in ("Read", "Edit", "Write", "NotebookEdit"):
            line = server.tool_line({"name": name, "input": {"file_path": "/a/b/c/foo.py"}})
            self.assertEqual(line, f"→ {name}: foo.py")

    def test_grep_glob_show_pattern(self):
        self.assertEqual(
            server.tool_line({"name": "Grep", "input": {"pattern": "TODO"}}),
            "→ Grep: TODO",
        )
        self.assertEqual(
            server.tool_line({"name": "Glob", "input": {"pattern": "**/*.py"}}),
            "→ Glob: **/*.py",
        )

    def test_task_agent_show_description(self):
        self.assertEqual(
            server.tool_line({"name": "Task", "input": {"description": "do a thing"}}),
            "→ Task: do a thing",
        )
        self.assertEqual(
            server.tool_line({"name": "Agent", "input": {"description": "explore code"}}),
            "→ Agent: explore code",
        )

    def test_unknown_tool_no_detail(self):
        self.assertEqual(server.tool_line({"name": "Mystery"}), "→ Mystery")
        # unknown tool with input we don't extract -> still no detail
        self.assertEqual(
            server.tool_line({"name": "Whatever", "input": {"foo": "bar"}}),
            "→ Whatever",
        )

    def test_long_detail_truncated(self):
        cmd = "x" * 200
        line = server.tool_line({"name": "Bash", "input": {"command": cmd}})
        self.assertTrue(line.endswith("…"))
        # "→ Bash: " prefix + 88 chars + "…"
        self.assertEqual(line, "→ Bash: " + "x" * 88 + "…")


class ReadTaskTest(unittest.TestCase):
    def setUp(self):
        self._orig_repo = server.REPO
        self.tmp = tempfile.mkdtemp()
        server.REPO = self.tmp
        os.makedirs(os.path.join(self.tmp, ".mux", "tasks"))
        self.task_path = os.path.join(self.tmp, ".mux", "tasks", "real.task.md")
        with open(self.task_path, "w") as f:
            f.write("# Task: real\nhello world\n")
        # a secret OUTSIDE the tasks tree that traversal must not reach
        self.secret = os.path.join(self.tmp, "secret.txt")
        with open(self.secret, "w") as f:
            f.write("SECRET-CONTENTS")

    def tearDown(self):
        server.REPO = self._orig_repo

    def test_valid_task_returns_contents(self):
        self.assertEqual(server.read_task("real.task.md"), "# Task: real\nhello world\n")

    def test_non_task_md_is_invalid(self):
        self.assertEqual(server.read_task("notes.md"), "(invalid task)")
        self.assertEqual(server.read_task("mux.sh"), "(invalid task)")

    def test_traversal_cannot_escape_tasks_dir(self):
        # basename-stripping turns "../../secret.txt" into "secret.txt" which is
        # not a .task.md -> invalid; and even a *.task.md traversal is stripped
        # to a basename inside .mux/tasks/, so the secret is never exposed.
        for attempt in ("../../etc/passwd", "../mux.sh", "../../secret.txt"):
            out = server.read_task(attempt)
            self.assertNotIn("SECRET-CONTENTS", out)
        # a traversal that keeps a .task.md suffix is basenamed into the tasks
        # dir, so it resolves to (task not found), never outside the tree.
        self.assertEqual(server.read_task("../../real.task.md"), "# Task: real\nhello world\n")


class PlanPageTest(unittest.TestCase):
    def setUp(self):
        self._orig_repo = server.REPO
        self.tmp = tempfile.mkdtemp()
        server.REPO = self.tmp
        os.makedirs(os.path.join(self.tmp, ".mux", "tasks"))
        with open(os.path.join(self.tmp, ".mux", "tasks", "foo.task.md"), "w") as f:
            f.write(
                "# Task: foo\n"
                "# STATUS: READY\n"
                "# Depends-on: x\n"
                "## Goal\n"
                "Do </script> the thing.\n"
            )

    def tearDown(self):
        server.REPO = self._orig_repo

    def test_title_and_chips_and_body_embedding(self):
        html = server.plan_page("foo.task.md")
        # title from "# Task: foo"
        self.assertIn("<title>foo</title>", html)
        self.assertIn("<div class=title>foo", html)  # title div text (</ escaped below)
        # non-Task metadata rendered as chips (</b> is escaped to <\/b> in the JSON-embedded HTML)
        self.assertIn("<b>STATUS<\\/b> READY", html)
        self.assertIn("<b>Depends-on<\\/b> x", html)
        # body is JSON-embedded and </ is escaped to <\/ (so no raw </script>)
        self.assertIn("<\\/script>", html)
        self.assertNotIn("</script> the thing", html)


class LogLinesTest(unittest.TestCase):
    def setUp(self):
        self._orig_repo = server.REPO
        self._orig_idle = server.idle_reason
        self.tmp = tempfile.mkdtemp()
        server.REPO = self.tmp

    def tearDown(self):
        server.REPO = self._orig_repo
        server.idle_reason = self._orig_idle

    def test_renders_events(self):
        logdir = os.path.join(self.tmp, ".mux", "log")
        os.makedirs(logdir)
        events = [
            {"type": "system", "subtype": "init"},   # only an init event opens a cycle
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "thinking out loud"},
                {"type": "tool_use", "name": "Bash", "input": {"command": "echo hi"}},
            ]}},
            {"type": "result", "result": "all done"},
        ]
        with open(os.path.join(logdir, "output.jsonl"), "w") as f:
            for ev in events:
                f.write(json.dumps(ev) + "\n")
        lines = server.log_lines()
        # The init event draws a kickoff phrase divider, prefixed with the
        # non-printing U+001F sentinel (the UI keys the divider class off it
        # and strips it), with no "cycle N" text and no GOL grid block.
        self.assertTrue(any(isinstance(l, str) and l.startswith("\x1f")
                            for l in lines))
        self.assertFalse(any(isinstance(l, str) and "█" in l for l in lines))
        self.assertFalse(any(isinstance(l, str) and "cycle" in l for l in lines))
        self.assertIn("● thinking out loud", lines)
        self.assertIn("→ Bash: echo hi", lines)
        self.assertIn("✓ all done", lines)

    def test_missing_log_yields_no_activity(self):
        # No .mux/log/output.jsonl exists; log_lines falls back to idle_reason.
        # Stub idle_reason so the fallback is deterministic and doesn't shell out.
        server.idle_reason = lambda: "No activity"
        self.assertEqual(server.log_lines(), ["No activity"])

    def test_long_markdown_message_renders_inline(self):
        # A multi-line markdown assistant message is NOT dumped raw into the log;
        # it becomes a dict entry carrying its full markdown body, which the UI
        # renders inline via marked.js.
        logdir = os.path.join(self.tmp, ".mux", "log")
        os.makedirs(logdir)
        md = "## Heading\n\n- a bullet\n- another **bold** line"
        events = [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "short note"},
                {"type": "text", "text": md},
            ]}},
        ]
        with open(os.path.join(logdir, "output.jsonl"), "w") as f:
            for ev in events:
                f.write(json.dumps(ev) + "\n")
        lines = server.log_lines()
        # short stays inline as a plain string; the raw markdown does not appear
        self.assertIn("● short note", lines)
        self.assertFalse(any(isinstance(l, str) and "## Heading" in l for l in lines))
        # the long one is a dict carrying its full markdown body verbatim
        dicts = [l for l in lines if isinstance(l, dict)]
        self.assertEqual(len(dicts), 1)
        self.assertEqual(dicts[0]["md"], md)
        self.assertEqual(dicts[0]["glyph"], "●")


class HttpRoutingTest(unittest.TestCase):
    def setUp(self):
        self._orig_repo = server.REPO
        self._orig_mux = server.mux
        self._orig_tasks = server.tasks
        self.tmp = tempfile.mkdtemp()
        server.REPO = self.tmp
        # stub tasks() so /api/tasks doesn't shell out to a real mux binary
        server.tasks = lambda: [{"file": "a.task.md", "status": "READY"}]
        # capture mux() invocations
        self.calls = []

        def fake_mux(*args):
            self.calls.append(args)
            return True, "ok-output"

        server.mux = fake_mux

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.H)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)
        server.REPO = self._orig_repo
        server.mux = self._orig_mux
        server.tasks = self._orig_tasks

    def _url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def _get(self, path):
        with urllib.request.urlopen(self._url(path)) as r:
            return r.status, r.headers.get("content-type", ""), r.read()

    def test_root_is_html(self):
        status, ctype, body = self._get("/")
        self.assertEqual(status, 200)
        self.assertIn("text/html", ctype)
        self.assertIn(b"MULTIPLEXER", body)

    def test_api_repo_returns_configured_repo(self):
        status, ctype, body = self._get("/api/repo")
        self.assertEqual(status, 200)
        self.assertIn("application/json", ctype)
        self.assertEqual(json.loads(body)["repo"], self.tmp)

    def test_api_tasks_returns_json_array(self):
        status, _, body = self._get("/api/tasks")
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertIsInstance(data, list)
        self.assertEqual(data[0]["status"], "READY")

    def test_missing_web_file_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._get("/web/does-not-exist.js")
        self.assertEqual(cm.exception.code, 404)

    def test_unknown_path_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._get("/nope")
        self.assertEqual(cm.exception.code, 404)

    def test_auto_get_reflects_marker_file(self):
        # Absent marker -> off; present -> on.
        status, _, body = self._get("/api/auto")
        self.assertEqual(json.loads(body), {"enabled": False})
        os.makedirs(os.path.join(self.tmp, ".mux"), exist_ok=True)
        open(os.path.join(self.tmp, ".mux", "auto"), "w").close()
        _, _, body = self._get("/api/auto")
        self.assertEqual(json.loads(body), {"enabled": True})

    def test_auto_post_creates_and_removes_marker(self):
        marker = os.path.join(self.tmp, ".mux", "auto")
        os.makedirs(os.path.join(self.tmp, ".mux"), exist_ok=True)

        def post(enabled):
            payload = json.dumps({"enabled": enabled}).encode()
            req = urllib.request.Request(
                self._url("/api/auto"), data=payload,
                headers={"content-type": "application/json"}, method="POST",
            )
            with urllib.request.urlopen(req) as r:
                return json.loads(r.read())

        self.assertEqual(post(True), {"enabled": True})
        self.assertTrue(os.path.exists(marker))
        self.assertEqual(post(False), {"enabled": False})
        self.assertFalse(os.path.exists(marker))

    def test_api_tasks_autopilot_approves_finished_task(self):
        # With .mux/auto present and a finished (dirty-tree, non-interrupted,
        # not-executing) RUNNING task, /api/tasks auto-approves it (mux ok).
        # Auto mode never releases drafts — the executor runs them in place — so
        # release-all must NEVER be called.
        os.makedirs(os.path.join(self.tmp, ".mux"), exist_ok=True)
        open(os.path.join(self.tmp, ".mux", "auto"), "w").close()
        server.tasks = lambda: [{"file": "r.task.md", "status": "RUNNING",
                                 "interrupted": False}]
        orig_status, orig_dirty = server.status, server.git_dirty_nonmux
        self.addCleanup(lambda: setattr(server, "status", orig_status))
        self.addCleanup(lambda: setattr(server, "git_dirty_nonmux", orig_dirty))
        server.status = lambda: {"executing": False, "elapsed": None}
        server.git_dirty_nonmux = lambda: True

        self._get("/api/tasks")
        self.assertIn(("ok",), self.calls)
        self.assertNotIn(("release-all",), self.calls)

    def test_api_tasks_autopilot_skips_ok_on_clean_tree(self):
        # Auto on, but the tree is clean: nothing to commit, so ok must NOT run
        # (and release-all is gone entirely).
        os.makedirs(os.path.join(self.tmp, ".mux"), exist_ok=True)
        open(os.path.join(self.tmp, ".mux", "auto"), "w").close()
        server.tasks = lambda: [{"file": "r.task.md", "status": "RUNNING",
                                 "interrupted": False}]
        orig_status, orig_dirty = server.status, server.git_dirty_nonmux
        self.addCleanup(lambda: setattr(server, "status", orig_status))
        self.addCleanup(lambda: setattr(server, "git_dirty_nonmux", orig_dirty))
        server.status = lambda: {"executing": False, "elapsed": None}
        server.git_dirty_nonmux = lambda: False

        self._get("/api/tasks")
        self.assertNotIn(("ok",), self.calls)
        self.assertNotIn(("release-all",), self.calls)

    def test_post_verb_forwards_argv_in_order(self):
        payload = json.dumps({"verb": "resolve", "id": "t1", "text": "my answer"}).encode()
        req = urllib.request.Request(
            self._url("/api/verb"), data=payload,
            headers={"content-type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req) as r:
            self.assertEqual(r.status, 200)
            d = json.loads(r.read())
        # JSON response echoes {ok, out} from the mux shim
        self.assertEqual(d, {"ok": True, "out": "ok-output"})
        # verb, id, text forwarded in order
        self.assertEqual(self.calls[-1], ("resolve", "t1", "my answer"))


class SendDisconnectTest(unittest.TestCase):
    """_send must not propagate a client disconnect. The web UI polls every 2s, so
    a browser that refreshes/navigates mid-response drops the socket — the write
    then fails with BrokenPipeError/ConnectionResetError. That is normal, not an
    error: swallow it so the request thread doesn't dump a traceback."""

    def _handler(self, wfile):
        h = server.H.__new__(server.H)   # bypass __init__ (no real socket)
        h.request_version = "HTTP/1.1"
        h.requestline = "GET / HTTP/1.1"
        h.wfile = wfile
        return h

    class _RaisingWfile:
        def __init__(self, exc):
            self.exc = exc
        def write(self, b):
            raise self.exc

    def test_broken_pipe_is_swallowed(self):
        h = self._handler(self._RaisingWfile(BrokenPipeError(32, "Broken pipe")))
        h._send(200, "ok")  # must not raise

    def test_connection_reset_is_swallowed(self):
        h = self._handler(self._RaisingWfile(ConnectionResetError(54, "Connection reset")))
        h._send(200, "ok")  # must not raise


class SpawnDirectTest(unittest.TestCase):
    """spawn_direct resumes the planner session when the DRAFT carries a valid
    `# Channel: <uuid>` header, else launches a fresh channel-scoped planner.
    We intercept subprocess.Popen so no Terminal is spawned, and assert on the
    osascript command string it would have run."""

    SID = "0123abcd-4567-89ab-cdef-0123456789ab"

    def setUp(self):
        self._orig_repo = server.REPO
        self._orig_popen = server.subprocess.Popen
        self.tmp = tempfile.mkdtemp()
        server.REPO = self.tmp
        os.makedirs(os.path.join(self.tmp, ".mux", "tasks"))
        self.captured = []
        server.subprocess.Popen = lambda argv, *a, **k: self.captured.append(argv)

    def tearDown(self):
        server.REPO = self._orig_repo
        server.subprocess.Popen = self._orig_popen

    def _write(self, name, body):
        with open(os.path.join(self.tmp, ".mux", "tasks", name), "w") as f:
            f.write(body)

    def _script(self):
        # The osascript -e argument carries the embedded `claude ...` command.
        self.assertEqual(len(self.captured), 1)
        argv = self.captured[0]
        self.assertEqual(argv[0], "osascript")
        return argv[-1]

    def test_resume_branch_when_channel_id_present(self):
        self._write("t.task.md",
                    f"# Task: t\n# STATUS: DRAFT\n# Channel: {self.SID}\n## Goal\nx\n")
        self.assertTrue(server.spawn_direct("t.task.md"))
        s = self._script()
        self.assertIn(f"claude --resume {self.SID} ", s)
        # planner scope re-passed alongside the resume
        self.assertIn("--setting-sources user", s)
        self.assertIn("Write(.mux/**)", s)
        self.assertIn("--append-system-prompt", s)

    def test_fresh_branch_when_channel_id_absent(self):
        self._write("t.task.md", "# Task: t\n# STATUS: DRAFT\n## Goal\nx\n")
        self.assertTrue(server.spawn_direct("t.task.md"))
        s = self._script()
        self.assertNotIn("--resume", s)
        self.assertIn("--setting-sources user", s)
        self.assertIn("Write(.mux/**)", s)

    def test_invalid_channel_id_falls_back_to_fresh(self):
        self._write("t.task.md",
                    "# Task: t\n# STATUS: DRAFT\n# Channel: not-a-uuid\n## Goal\nx\n")
        self.assertTrue(server.spawn_direct("t.task.md"))
        self.assertNotIn("--resume", self._script())

    def test_bad_basename_returns_false_without_spawning(self):
        self.assertFalse(server.spawn_direct("notes.md"))
        self.assertFalse(server.spawn_direct("../escape.task.md"))  # missing file
        self.assertEqual(self.captured, [])


if __name__ == "__main__":
    unittest.main()

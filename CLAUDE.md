# CLAUDE.md

## What this is

claude-mux is a planner/executor task loop driven by markdown task files in
`.mux/tasks/`. A **planner** reads the repo and writes task files; a human
releases the ones they want run; a headless **executor** runs them one at a
time, oldest first, and commits each on human approval. A small web dashboard
watches the executor and exposes the task board with action buttons.

Task files are the single source of truth. Every state change goes through the
`mux` CLI — nothing else should hand-edit a task's `# STATUS:` line.

## The pieces

- `mux/mux.sh` — the CLI ("verb layer"): the only sanctioned way to change a
  task's state. Verbs dispatch to `cmd_*` functions (see the `case` at the
  bottom): `add`, `release`/`release-all`, `claim`, `block`, `resolve`, `ok`,
  `changes`, `revert`, `fail`, `show`, `status`/`ls`, `board`, `next`,
  `planner`, `web`/`start`, `executor`, `tick`, `stop`, `help`. The top-of-file
  comment block is the canonical usage reference.
- `mux/server.py` — the `mux web` dashboard (stdlib only, no deps). Serves the
  repo's `.mux/` queue at `http://127.0.0.1:<port>` (default 8770); every action
  shells out to `mux`. UI accent/label come from the `THEMES` map.
- `mux/web/` — front-end assets: `index.html` plus vendored `marked.min.js` and
  `github-markdown.min.css` under `vendor/`.
- `mux/prompts/PLANNER.md`, `mux/prompts/EXECUTOR.md` — the two role prompts.
- `mux/tests/` — `test_mux.sh` and `test_server.py` (see below).
- `install.sh` — symlinks `mux/mux.sh` onto your PATH (default `~/.local/bin`);
  one checkout serves every repo, which `mux` locates via `git rev-parse`.
- `docs/` — repo assets (e.g. `banner.svg`).

## Task lifecycle

States (see `task_status` / `set_status` in `mux.sh`):

    DRAFT → READY → RUNNING → DONE
                       ├────→ FAILED
                       └────→ BLOCKED → (resolve) → READY

`mux add` creates a DRAFT; `release` makes it READY; the executor `claim`s it to
RUNNING; `ok` commits the working tree and marks it DONE; `revert`/`fail` discard
to FAILED; `block` parks it with a question (BLOCKED) until `resolve` re-queues
it.

## Task-file format

Files are `.mux/tasks/<timestamp>-<slug>.task.md`. The header lines an
executor/planner reads (exact spellings, parsed in `mux.sh`):

- `# STATUS:` — the state (see `task_status` / `set_status`).
- `# Depends-on:` — another task's id; `mux next` won't run this until that dep
  is DONE (see `task_dep` / `dep_is_done`).
- `# Session:` — the executor session id, recorded while RUNNING (`task_session`
  / `record_session`).

`mux add`'s template is `# Task:` / `# STATUS:` / `## Goal` / `## Details`.

## Selection rule

`mux next` prints the ONE task to act on: a RUNNING task if one exists,
otherwise the FIFO-oldest READY task whose `# Depends-on:` is DONE or absent.
One task at a time.

## Running the tests

- `mux/tests/test_mux.sh` — bash suite for the verb layer / `cmd_next`; run it
  directly (`./mux/tests/test_mux.sh`).
- `mux/tests/test_server.py` — stdlib unittest for `server.py`; run
  `python3 mux/tests/test_server.py` or `python3 -m unittest mux.tests.test_server`.

## Hard rule for planners

Planners may write files **only** under `.mux/` and must never modify source
code (enforced by permissions — see `mux/prompts/PLANNER.md`).

<div align="center">

<pre>
▗▖  ▗▖▗▖ ▗▖▗▖ ▗▄▄▄▖▗▄▄▄▖▗▄▄▖ ▗▖   ▗▄▄▄▖▗▖  ▗▖▗▄▄▄▖▗▄▄▖
▐▛▚▞▜▌▐▌ ▐▌▐▌   █    █  ▐▌ ▐▌▐▌   ▐▌    ▝▚▞▘ ▐▌   ▐▌ ▐▌
▐▌  ▐▌▐▌ ▐▌▐▌   █    █  ▐▛▀▘ ▐▌   ▐▛▀▀▘  ▐▌  ▐▛▀▀▘▐▛▀▚▖
▐▌  ▐▌▝▚▄▞▘▐▙▄▄▖█  ▗▄█▄▖▐▌   ▐▙▄▄▖▐▙▄▄▖▗▞▘▝▚▖▐▙▄▄▖▐▌ ▐▌
</pre>

**Multiplexer** — a multiplexer for [Claude Code](https://claude.com/claude-code).

Many minds plan in parallel. One builds. You approve every commit.

![built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-d97757)
![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

</div>

<img src="docs/multiplexer.png" alt="The Multiplexer web UI: the QUEUE panel on the left lists task files with per-state action buttons, the read-only live Output panel is on the right, and the MULTIPLEXER brand sits top-left." width="100%">

## What it is

Multiplexer splits Claude Code into two roles connected by a queue:

- **Channels** — read-only sessions that explore the repo and write _task
  files_. Run as many as you like, in parallel. They cannot touch your source.
- **Output** — one worker that picks up tasks, does the work, and commits
  **only after you say `ok`**.

You sit in the middle: you release which tasks run, and approve every commit.
No frameworks, no services, no SDK — just the Claude Code CLI and a single
shell command (`mux`) you can read top to bottom.

It's two patterns, each useful alone:

- **Multiplexer** — many parallel channels, one serial output. Planning is
  safe (no source write access); execution is privileged. No agents fight over the tree.
- **Gated loop** — the output loops on a timer but commits nothing on its own.
  Autonomous about _when_ it works, never about _what_ lands.

## Quickstart

One checkout, symlinked onto your PATH **once**, works in every repo:

```bash
# one-time: link the `mux` command onto your PATH
git clone <this-repo> ~/code/multiplexer
~/code/multiplexer/install.sh       # symlinks `mux` into ~/.local/bin

# then, in ANY git repo:
mux channel          # open a channel — as many as you like
mux status           # see the queue   (or `mux board` for an interactive view)
mux release <id>     # you release a DRAFT task to READY so it may run
mux start            # open the web view + start the output (default :8770)
```

`mux start` is the main entry point: it serves the web UI and runs the
output loop together. Prefer the terminal? `mux output` runs just the loop
(polls every 10s; pass an interval like `mux output 30s`). Stop everything
for this repo with `mux stop`.

`mux` finds each repo and its queue itself (via `git rev-parse`), so nothing is
copied per-repo — update everywhere with a single `git pull` in the checkout.
Your queue lives in `.mux/` at the repo root; keep it out of git however you
like (e.g. `echo '.mux/' >> ~/.config/git/ignore`).

Everything is one command — run `mux help` for the full verb list. You release
a drafted task with `mux release <id>`, and the board is also machine-readable
via `mux status --json` (for editors, Raycast, a future UI, …).

## Using the web UI

`mux start` is the cockpit: it serves a page at `http://127.0.0.1:8770` **and**
runs the output loop behind it. From the page you drive the whole workflow —
**except** talking to a channel, which is an interactive Claude session and so
opens in its own terminal.

The page has two panels and one button:

- **Queue** (left) — the queue of task files. Each task shows the one action its
  state allows: `release` (DRAFT → READY), `approve` / `revert` (a finished
  RUNNING task), or `answer` (a BLOCKED one). Click a task's name to open its plan.
- **Output** (right) — the worker's live log, **read-only**. You watch it;
  you never type into it.
- **Task +** (beside the Queue heading) — opens a **new terminal window** with a
  channel session. You converse with it there to draft tasks; it can't run in the
  browser.

So the loop, end to end:

| Step | Where | You do |
| ---- | ----- | ------ |
| 1. Draft tasks  | terminal (via **+ channel**) | converse with the channel |
| 2. Release      | **web UI** | click `release` on a DRAFT |
| 3. Work happens | background loop → right panel | watch the live log |
| 4. Approve      | **web UI** | click `approve` (commits) or `revert` |
| 5. Answer a block | **web UI** | click `answer`, type a reply |

Every button just calls the matching CLI verb (`mux release`, `mux ok`,
`mux revert`, `mux resolve`), so you can do any of it from the terminal instead
— the two gates below hold either way.

## Task lifecycle

Tasks are one file each in `.mux/tasks/`, timestamp-named (FIFO), carrying a
`# STATUS:`.

| Status    | Meaning                                | Set by                     |
| --------- | -------------------------------------- | -------------------------- |
| `DRAFT`   | Written by a channel, not yet released | channel                    |
| `READY`   | Released — the output may run it     | **you**                    |
| `RUNNING` | In flight, or paused awaiting you      | output                   |
| `DONE`    | Finished and committed                 | output (after your `ok`) |
| `FAILED`  | Unworkable — see its `# Reason:`       | output                   |

Only one task runs at a time: while anything is `RUNNING`, the loop starts
nothing else, so it can pause for your review as long as needed.

## The two gates

1. **Release** — channels only produce `DRAFT`s. Nothing runs until _you_ release
   one to `READY` (`mux release <id>`). Want strict one-at-a-time? Keep just one `READY`.
2. **Commit** — the output does the work, then stops with the change
   uncommitted and waits. Say `ok` → it commits and marks the task `DONE`. Ask
   for changes → it revises. It never commits without you.

Channels enforce gate 1 by construction: they launch scoped to
`Write(./.mux/**)` only, so they can read everything but write nowhere but the
queue — enforced by Claude Code, not by trust.

## Sessions & branches

A **session** is one branch. You choose it when you `mux start`, everything you
commit lands on it, and you finish the session by pushing it.

**Pick the branch at start.** On a genuinely fresh start — clean tree,
everything pushed, nothing `RUNNING` — `mux start` prompts for the branch this
session will use:

- **Enter** — continue on the current branch.
- **`n <name>`** — create a NEW branch (off the current one) and switch to it.
- **`e`** — choose an EXISTING local branch from a numbered list.

Prefer one shot? `mux start <branch>` skips the prompt and creates-or-checks-out
that branch (`mux start <branch> <port>` to also set the web port). Everything
you commit this session lands wherever you land here; mux records it so the
session knows where to return at the end.

**mux operates only on the live branch.** It checks out the branch you choose at
start and pushes it at the end. During a session it never switches, merges, or
rebases branches — your commits simply stack on the one branch.

**A fresh prompt, or a quiet continue.** The branch prompt appears only on that
fresh slate. If a previous session is still in flight — an uncommitted change, a
commit not yet pushed (including `COMMITTED` tasks awaiting push), or a task
still `RUNNING` — `mux start` skips the prompt and quietly continues that branch,
so you never get asked mid-session. Leftover `DRAFT` proposals from channels are
branch-neutral and never count as in-flight; they carry over fine.

**The lifecycle, end to end:**

1. **`mux start`** — pick or create the branch (see above).
2. **Channels propose, output works.** Channels draft tasks; you release them;
   the output runs the one in flight (`RUNNING`).
3. **Review the diff** in the web UI.
4. **`mux ok`** (the `approve` button) commits the working tree to the branch.
   The task moves to `COMMITTED` — committed, but not yet pushed. Several can
   stack up this way across the session.
5. **Ship** (the header button, or `mux end`) pushes the branch to its upstream,
   clears the `COMMITTED` tasks off the board, returns you to the base branch,
   and tears down the loop + UI — ready for the next `mux start`. It refuses
   while a task is `RUNNING` or the tree is dirty: resolve that first.

**Stepping away without pushing.** To pause, just stop the CLI — Ctrl-C,
closing the terminal, or `mux stop`. That tears down the loop and web UI but
leaves the branch, its commits, and the whole queue intact. Resume later with
`mux start` and continue right where you left off. There is no separate "pause"
button; stopping *is* the pause, and **Ship** is the only finalize.

**Not part of mux today.** Anything beyond pick/create-at-start and push-at-end
is out of scope: no mid-session branch switching, no merges, no PR creation.

## Requirements

- [Claude Code](https://claude.com/claude-code) CLI
- `git`, `bash` (standard on macOS/Linux)
- `fzf` — optional, only for the interactive `mux board`

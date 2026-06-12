<div align="center">

# Claude MUX

**A multiplexer for [Claude Code](https://claude.com/claude-code).**

Many minds plan in parallel. One builds. You approve every commit.

*Scale Claude's thinking without losing control of the code.*

![built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-d97757)
![shell](https://img.shields.io/badge/shell-bash-4EAA25)
![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

</div>

---

## What is this?

Claude MUX splits Claude Code into two roles so you can think in parallel but
ship in a single, controlled line:

- **Planners** — several read-only sessions, one per slice of a problem (UI,
  API, auth…). They read your whole repo but can only *write task files*. They
  never touch your source.
- **Executor** — one worker session that picks tasks off the queue, does the
  work, shows you the diff, and commits **only after you say OK**.

You're the orchestrator in the middle: you decide which tasks run, and nothing
lands without your word.

No frameworks, no services, no SDK — just the official Claude Code CLI and a few
shell scripts you can read top to bottom.

## How it works

```
   planner      planner      planner       you, thinking in parallel.
     ui          api          auth         each reads your repo but can
      │           │            │           only write into .mux/
      └─────┬─────┴─────┬──────┘
            ▼           ▼
   ┌────────────────────────────┐
   │   .mux/tasks/   (the queue) │   planners drop tasks here as DRAFT
   │                            │
   │   • fix-redirect   READY   │ ◀─ GATE 1: you flip DRAFT → READY.
   │   • add-login      DRAFT   │           nothing runs until you do.
   └─────────────┬──────────────┘
                 ▼  oldest READY first
          ┌────────────┐
          │  executor  │   one worker, looping. claims a task,
          │   (loop)   │   does it, shows you the diff, waits…
          └─────┬──────┘
                ▼  you review → "ok"
            git commit       ◀─ GATE 2: never without your approval.
```

## Quickstart

```bash
# 1. clone this repo, then install into ANY git repo you work in:
./install.sh /path/to/your/repo

# 2. in your repo, two terminal tabs:
.claude/mux/executor.sh          # tab 1 — the worker (loops every 5m)
.claude/mux/planner.sh           # tab 2 — a planner; open as many as you like

# 3. see the queue any time:
.claude/mux/status.sh
```

The installer drops everything into `.claude/mux/` and hides it via the repo's
`.git/info/exclude`, so **it's never tracked, committed, or seen by your
teammates.** Re-run anytime to update — it won't touch your task queue.

## The pieces

| Piece | What it is |
|-------|------------|
| **Planner** (`planner.sh`) | A producer. Reads your whole repo, writes only under `.mux/`. Discuss one slice of the problem; it writes a task file. Run several in parallel. |
| **Queue** (`.mux/tasks/`) | One file per task, timestamp-named so order is FIFO. Each carries a `# STATUS:`. |
| **Executor** (`executor.sh`) | The single consumer. Loops over `READY` tasks, does each, pauses for your OK before committing. |
| **You** | The orchestrator. You release tasks (`DRAFT → READY`) and approve every commit. |

## Task lifecycle

| Status | Meaning | Set by |
|--------|---------|--------|
| `DRAFT` | Produced by a planner, not yet released | planner |
| `READY` | You've released it — the executor may run it | **you** (edit the file) |
| `RUNNING` | Claimed and in flight, or paused awaiting you | executor |
| `DONE` | Finished and committed | executor (after your OK) |
| `FAILED` | Unworkable as written — see its `# Reason:` | executor |

While anything is `RUNNING`, the loop **starts nothing else** — so the executor
can pause for a decision or your review as long as you need, without stacking up
work. One task in flight, ever.

## Two gates keep you in charge

Neither requires babysitting:

1. **Release gate.** Planners only ever produce `DRAFT`s. Nothing runs until
   *you* flip a task to `READY`. Want strict one-at-a-time? Keep just one `READY`.
2. **Commit gate.** The executor does the work, then **stops with the change
   uncommitted** (review it in your editor's *Changes* panel) and waits. Say
   `ok` → it commits and marks the task `DONE`. Ask for changes → it revises.
   **It never commits without your approval.**

So the "loop" isn't an autonomous committer — it's an assistant that does the
work and waits at the gate.

## Why planners can't touch your code

Planner sessions launch with scoped permissions
(`--allowedTools 'Write(./.mux/**)' 'Edit(./.mux/**)' … --setting-sources user`),
so they can **read everything but write only inside `.mux/`**. A planner
literally cannot modify your source — enforced by Claude Code, not by trust. The
executor is the one and only session with full write access.

## Requirements

- [Claude Code](https://claude.com/claude-code) CLI
- `git` and `uuidgen` (standard on macOS/Linux)
- bash

#!/usr/bin/env bash
# executor.sh — the ONE worker that writes code.
#
# It consumes READY tasks from .mux/tasks/ (oldest first), does each one, shows
# you the diff, and commits ONLY after you say OK. Run it in its own tab.
#   .claude/mux/executor.sh            -> AUTOPILOT: loop every 5m (default)
#   .claude/mux/executor.sh 10m        -> autopilot with a custom interval
#   .claude/mux/executor.sh --manual   -> MANUAL: you say "do the next task"

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # where this script + prompts live
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"
mkdir -p .mux/tasks

ARG="${1:-}"
if [ "$ARG" = "--manual" ]; then
  MODE="manual"
else
  MODE="loop"
  INTERVAL="${ARG:-5m}"     # bare -> 5m; pass an interval (e.g. 10m) to change
fi

CYCLE='Run one work cycle. FIRST: if any .mux/tasks/*.task.md has STATUS RUNNING, do NOTHING this tick (a task is in progress, paused for a decision, or awaiting the human OK to commit) — never start a second task while one is RUNNING. Otherwise, among tasks whose STATUS is READY pick the one whose filename sorts first, set its STATUS to RUNNING, then do exactly what it says, running only the tests it names. If you need a human decision, ASK and stop, leaving it RUNNING. When the change is complete, do NOT commit — summarize the files changed and STOP, leaving it RUNNING, and wait for the human to approve. ONLY when they say ok do you commit referencing the task file and set its STATUS to DONE; if they ask for changes, revise and present again without committing. Never commit before the human says ok. If the task is truly unworkable, set its STATUS to FAILED with a one-line Reason. Never have two tasks RUNNING. If there is no READY task, do nothing this tick.'

echo "▶ EXECUTOR (worker) — does the work, then waits for your OK before committing"
echo "  repo:   $REPO_ROOT"
echo "  branch: $(git branch --show-current 2>/dev/null || echo '?')"
echo

if [ "$MODE" = "manual" ]; then
  echo "  MANUAL: say  'do the next task'  to run one cycle and watch it."
  echo
  exec claude \
    -n "executor" \
    --dangerously-skip-permissions \
    --append-system-prompt "$(cat "$DIR/prompts/EXECUTOR.md")"
else
  echo "  AUTOPILOT: looping every ${INTERVAL}. Picks up one READY task, does it,"
  echo "  then PAUSES for your OK before committing (loop idles until you reply)."
  echo "  Say 'ok' to commit, or ask for changes. Ctrl-C / 'stop' to halt."
  echo "  (--manual to drive each cycle yourself.)"
  echo
  exec claude \
    -n "executor" \
    --dangerously-skip-permissions \
    --append-system-prompt "$(cat "$DIR/prompts/EXECUTOR.md")" \
    "/loop ${INTERVAL} ${CYCLE}"
fi

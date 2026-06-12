#!/usr/bin/env bash
# status.sh — the orchestrator's board.
#
# Shows the task queue: what the planners produced, each task's status, and the
# one the executor will pick next. You orchestrate by editing the files:
#   DRAFT   -> produced by a planner, NOT yet released by you
#   READY   -> you released it (flip STATUS to READY); executor runs it
#   RUNNING -> executor is on it (or paused awaiting you); loop won't start others
#   DONE    -> executor finished it
#   FAILED  -> executor couldn't run it (open the file for its Reason)
# Order is FIFO by filename (timestamped). To run something sooner, mark it
# READY before older drafts; to hold it back, leave it DRAFT.

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

shopt -s nullglob
tasks=(.mux/tasks/*.task.md)
[ ${#tasks[@]} -gt 0 ] || { echo "no tasks yet — open a planner:  .claude/mux/planner.sh"; exit 0; }

printf '%-3s %-7s %s\n' "" "STATUS" "TASK"
printf '%-3s %-7s %s\n' "" "------" "----"
next_marked=0
for f in "${tasks[@]}"; do          # filename sort == FIFO order
  status="$(grep -m1 -i '^# STATUS:' "$f" | sed 's/.*STATUS:[[:space:]]*//' | awk '{print $1}')"
  status="${status:-DRAFT}"
  marker="   "
  if [ "$status" = "RUNNING" ]; then
    marker=" * "; next_marked=1          # something in flight; loop is gated
  elif [ "$status" = "READY" ] && [ "$next_marked" -eq 0 ]; then
    marker=" > "; next_marked=1
  fi
  printf '%s %-7s %s\n' "$marker" "$status" "$(basename "$f")"
done
echo
echo " *  = in progress / awaiting you (loop holds until this clears)"
echo " >  = next READY task the executor will pick"

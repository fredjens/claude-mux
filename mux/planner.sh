#!/usr/bin/env bash
# planner.sh — open a PLANNER (task producer).
#
# A planner can READ your whole repo but may WRITE only under .mux/ (enforced
# by per-session permissions). It plans one part of the problem and writes task
# files for the executor to run. Open as many as you like; keep one open as
# long as you want — a long-running planner just keeps producing tasks.
#
# Usage:  .claude/mux/planner.sh            # unnamed planner
#         .claude/mux/planner.sh auth       # named (just for your own clarity)

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # where this script + prompts live
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"
mkdir -p .mux/tasks

NAME="${1:-planner}"

echo "◆ PLANNER (producer): ${NAME}"
echo "  reads your code; may write ONLY under .mux/ — cannot touch source"
echo "  writes tasks to .mux/tasks/<timestamp>-<slug>.task.md as DRAFT"
echo "  YOU flip them to READY (edit the file); executor runs READY oldest-first"
echo "  see the queue any time:  .claude/mux/status.sh"
echo

# Per-session scoped permissions:
#  --setting-sources user  -> ignore project settings, so a broad project
#       allow-rule can't widen this session's write scope.
#  --allowedTools 'Write(./.mux/**)' 'Edit(./.mux/**)' -> pre-approve writes
#       under .mux only; --permission-mode default makes any OTHER write prompt
#       you (so a stray code edit can't happen silently).
exec claude \
  -n "planner:${NAME}" \
  --setting-sources user \
  --permission-mode default \
  --allowedTools 'Read' 'Glob' 'Grep' 'Bash' 'Write(./.mux/**)' 'Edit(./.mux/**)' \
  --append-system-prompt "$(sed "s/__NAME__/${NAME}/g" "$DIR/prompts/PLANNER.md")"

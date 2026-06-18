#!/usr/bin/env bash
# mux.sh — the VERB LAYER: the only sanctioned way to change a task's state.
#
# Every legal move in the workflow is one subcommand here. Nothing else should
# hand-edit a task's STATUS — you, a hook, the executor tick, or a future UI all
# go through these verbs, so the rules (a DRAFT can't commit, a RUNNING task
# can't be released, etc.) live in ONE place and illegal moves are refused.
#
# Source of truth stays the files in .mux/tasks/*.task.md. These verbs only do
# validated edits to those files; git (committing on `ok`) is the executor's job.
#
#   mux planner  [name]         open a planner (reads repo, writes only .mux/)
#   mux start    [port]         open the web view + auto-start the executor (default :8770)
#   mux web      [port]         alias of `mux start`
#   mux stop                    stop this repo's web UI + executor loop
#   mux executor [interval]     headless executor loop on its own (web starts this for you)
#   mux tick                    run ONE headless cycle (for launchd/cron)
#   mux add  <slug> [goal...]   create a DRAFT task
#   mux ls | status             the board
#   mux status --json           machine-readable board (for fzf/Raycast/UIs)
#   mux board                   interactive board (fzf): preview + verb keys
#   mux next                    the one task the executor should run now
#   mux show     <id>           print a task file
#   mux release  <id>           DRAFT  -> READY   (you release it to run)
#   mux claim    <id>           READY  -> RUNNING (executor claims it; not for you)
#   mux block    <id> <q...>    RUNNING-> BLOCKED (park with a question)
#   mux resolve  <id> [a...]    BLOCKED-> READY   (answer + re-queue)
#   mux ok       [note...]      approve RUNNING: commit the changes -> DONE
#   mux revert                  reject RUNNING: discard the changes -> FAILED
#   mux fail     <id> <why...>  RUNNING-> FAILED  (executor: discard + reason)
#   mux help
#
# <id> is any unique substring of a task's filename (usually its slug).

set -euo pipefail

# This script's REAL directory, following symlinks — so a single checkout can be
# symlinked onto PATH (`ln -s .../mux/mux.sh ~/.local/bin/mux`) and still find its
# prompts/. Computed BEFORE we cd, while BASH_SOURCE is still relative to $PWD.
resolve_self_dir() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -h "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
SELF_DIR="$(resolve_self_dir)"
PROMPTS_DIR="$SELF_DIR/prompts"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"
mkdir -p .mux/tasks
shopt -s nullglob

TASKS=.mux/tasks

# --- helpers ---------------------------------------------------------------

die() { echo "✗ $*" >&2; exit 1; }

stamp() { date '+%Y-%m-%d %H:%M'; }

# STATUS of a task file (defaults to DRAFT if the line is absent).
task_status() {
  local s
  s="$(grep -m1 -i '^# STATUS:' "$1" | sed 's/.*STATUS:[[:space:]]*//' | awk '{print $1}' || true)"
  echo "${s:-DRAFT}"
}

# Rewrite the first "# STATUS:" line in place (portable: temp file + mv).
set_status() {
  local f="$1" new="$2" tmp
  tmp="$(mktemp)"
  awk -v s="$new" '
    /^# STATUS:/ && !done { print "# STATUS: " s; done=1; next }
    { print }
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
}

append_block() { printf '\n%s\n' "$2" >> "$1"; }

# Minimal JSON string escaping (backslash + double-quote).
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Is the RUNNING task approved? / dependency of a task and its done-state.
task_dep()   { grep -m1 -i '^# Depends-on:' "$1" | sed 's/.*Depends-on:[[:space:]]*//' | awk '{print $1}' || true; }

# Value of a single-token header field (Branch, Base, …); '' if absent.
task_field() { grep -m1 -i "^# *$2:" "$1" 2>/dev/null | sed 's/.*: *//' | awk '{print $1}' || true; }

# True when the working tree has no uncommitted changes — IGNORING mux's own
# .mux/ queue (it's metadata, never "work"), whether or not it's gitignored.
git_clean() {
  local line
  while IFS= read -r line; do
    case "${line:3}" in
      .mux/*|.mux|"") ;;     # mux's queue doesn't count
      *) return 1 ;;
    esac
  done < <(git status --porcelain 2>/dev/null)
  return 0
}

# Build a titled commit message from a task file (+ optional approval note).
commit_message() {
  local f="$1" note="${2:-}" slug goal
  slug="$(grep -m1 -i '^# Task:' "$f" | sed 's/^# *[Tt]ask:[[:space:]]*//')"
  goal="$(awk '/^## *Goal/{g=1;next} g&&NF{print;exit}' "$f")"
  printf '%s: %s\n\ntask: %s' "${slug:-task}" "${goal:-see task file}" "${f##*/}"
  [ -n "$note" ] && printf '\n\n%s' "$note"
  return 0
}

# Resolve a unique task file from a filename substring.
resolve_id() {
  local q="${1%.task.md}"                       # tolerate a full filename
  local matches=( "$TASKS"/*"$q"*.task.md )
  [ ${#matches[@]} -gt 0 ] || die "no task matches '$1'"
  if [ ${#matches[@]} -gt 1 ]; then
    { echo "✗ '$q' is ambiguous — matches:"; printf '   %s\n' "${matches[@]##*/}"; } >&2
    exit 1
  fi
  printf '%s\n' "${matches[0]}"
}

# The single RUNNING task (the invariant is at most one).
running_task() {
  local f found="" n=0
  for f in "$TASKS"/*.task.md; do
    if [ "$(task_status "$f")" = RUNNING ]; then found="$f"; n=$((n+1)); fi
  done
  [ "$n" -gt 0 ] || die "no task is RUNNING — nothing to approve or revise"
  [ "$n" -eq 1 ] || die "more than one task is RUNNING (invariant broken); fix the queue by hand"
  printf '%s\n' "$found"
}

# Refuse an illegal transition with a clear message.
require_status() {
  local f="$1" want="$2" have
  have="$(task_status "$f")"
  [ "$have" = "$want" ] || die "${f##*/} is $have, not $want — refused"
}

# --- verbs -----------------------------------------------------------------

cmd_add() {
  [ $# -ge 1 ] || die "usage: mux add <slug> [goal...]"
  local slug ts f goal
  slug="$(echo "$1" | tr ' ' '-')"; shift
  goal="${*:-<one clear outcome; what \"done\" looks like>}"
  ts="$(date +%Y%m%d-%H%M%S)"
  f="$TASKS/$ts-$slug.task.md"
  cat > "$f" <<EOF
# Task: $slug
# STATUS: DRAFT
## Goal
$goal
## Details
-
EOF
  echo "+ ${f##*/}  (DRAFT) — edit it, then:  mux release $slug"
}

cmd_release() {
  [ $# -ge 1 ] || die "usage: mux release <id>"
  local f; f="$(resolve_id "$1")"
  require_status "$f" DRAFT
  set_status "$f" READY
  echo "→ ${f##*/}  DRAFT → READY"
}

cmd_block() {
  [ $# -ge 2 ] || die "usage: mux block <id> <question...>"
  local f; f="$(resolve_id "$1")"; shift
  require_status "$f" RUNNING
  set_status "$f" BLOCKED
  append_block "$f" "## Question ($(stamp))
$*"
  echo "⏸ ${f##*/}  RUNNING → BLOCKED (loop keeps going on other tasks)"
}

cmd_resolve() {
  [ $# -ge 1 ] || die "usage: mux resolve <id> [answer...]"
  local f; f="$(resolve_id "$1")"; shift
  require_status "$f" BLOCKED
  [ $# -gt 0 ] && append_block "$f" "## Answer ($(stamp))
$*"
  set_status "$f" READY
  echo "→ ${f##*/}  BLOCKED → READY"
}

cmd_claim() {
  [ $# -ge 1 ] || die "usage: mux claim <id>"
  local f; f="$(resolve_id "$1")"
  require_status "$f" READY
  git_clean || die "working tree not clean — commit or stash your own changes first"
  set_status "$f" RUNNING
  echo "▶ ${f##*/}  READY → RUNNING   (on $(git branch --show-current 2>/dev/null || echo '?'))"
}

# Throw away all uncommitted work EXCEPT the .mux queue. Safe because the
# executor always starts from a clean tree — anything dirty is this task's work.
discard_changes() {
  git checkout -q -- . 2>/dev/null || true
  git clean -fdq -e .mux 2>/dev/null || true
}

cmd_fail() {
  [ $# -ge 2 ] || die "usage: mux fail <id> <reason...>"
  local f; f="$(resolve_id "$1")"; shift
  require_status "$f" RUNNING
  discard_changes
  set_status "$f" FAILED
  append_block "$f" "# Reason: $*"
  echo "✗ ${f##*/}  RUNNING → FAILED  (changes discarded)"
}

# Human rejects the finished work: discard the executor's changes, mark FAILED.
cmd_revert() {
  local f; f="$(running_task)"
  discard_changes
  set_status "$f" FAILED
  append_block "$f" "# Reverted: $(stamp)${*:+ — $*}"
  echo "↩ ${f##*/} reverted — changes discarded, marked FAILED"
}

# Approve the RUNNING task: commit its working-tree changes as ONE commit on the
# CURRENT branch, then mark DONE. No branches to track — commits wherever you are.
cmd_ok() {
  local f; f="$(running_task)"
  git_clean && die "no file changes to commit for ${f##*/} — ask for changes, or 'mux fail'"
  # Stage everything, then unstage the queue so it's never committed. (A pathspec
  # exclude like ':!.mux' instead would FAIL when .mux is gitignored; this works
  # whether .mux is ignored — then the reset is a harmless no-op — or not.)
  git add -A || die "git add failed"
  git reset -q -- .mux 2>/dev/null || true
  git commit -q -m "$(commit_message "$f" "$*")" || die "git commit failed"
  local sha br; sha="$(git rev-parse --short HEAD)"; br="$(git branch --show-current 2>/dev/null || echo '?')"
  set_status "$f" DONE
  append_block "$f" "# Done: $(stamp) · $sha on $br"
  echo "✓ ${f##*/} → DONE   ($sha on $br)"
}

cmd_changes() {
  [ $# -ge 1 ] || die "usage: mux changes <note...>"
  local f; f="$(running_task)"
  append_block "$f" "## Change request ($(stamp))
$*"
  echo "↻ ${f##*/} — revision requested; stays RUNNING, executor revises next tick"
}

cmd_show() {
  [ $# -ge 1 ] || die "usage: mux show <id>"
  cat "$(resolve_id "$1")"
}

cmd_status() {
  [ "${1:-}" = "--json" ] && { cmd_status_json; return; }
  local tasks=( "$TASKS"/*.task.md )
  [ ${#tasks[@]} -gt 0 ] || { echo "no tasks yet — open a planner:  mux planner"; return 0; }
  printf '%-3s %-7s %s\n' "" "STATUS" "TASK"
  printf '%-3s %-7s %s\n' "" "------" "----"
  local f status marker dep depstatus note next_marked=0
  for f in "${tasks[@]}"; do          # filename sort == FIFO
    status="$(task_status "$f")"
    marker="   "
    if [ "$status" = RUNNING ]; then marker=" * "; next_marked=1
    elif [ "$status" = READY ] && [ "$next_marked" -eq 0 ]; then marker=" > "; next_marked=1
    fi
    note=""
    grep -qi '^## Approved' "$f" && note=" (approved)"
    [ "$status" = BLOCKED ] && note=" (awaiting answer)"
    dep="$(task_dep "$f")"
    if [ -n "$dep" ]; then
      depstatus=pending
      [ -f "$TASKS/$dep" ] && [ "$(task_status "$TASKS/$dep")" = DONE ] && depstatus=done
      note="$note (depends: ${dep%%.task.md} [$depstatus])"
    fi
    printf '%s %-7s %s%s\n' "$marker" "$status" "${f##*/}" "$note"
  done
  echo
  echo " *  = RUNNING / awaiting you (loop holds this task; BLOCKED ones don't gate)"
  echo " >  = next READY task the executor will pick"
}

# The board as JSON — one source of truth for every UI (fzf, Raycast, web...).
cmd_status_json() {
  local tasks=( "$TASKS"/*.task.md )
  [ ${#tasks[@]} -gt 0 ] || { printf '[]\n'; return 0; }
  local f status dep depstatus approved awaiting current next exec_now next_marked=0 sep=""
  local executing=false; [ -d .mux/tick.lock ] && executing=true
  printf '['
  for f in "${tasks[@]}"; do
    status="$(task_status "$f")"
    current=false; next=false
    if [ "$status" = RUNNING ]; then current=true; next_marked=1
    elif [ "$status" = READY ] && [ "$next_marked" -eq 0 ]; then next=true; next_marked=1
    fi
    exec_now=false; [ "$status" = RUNNING ] && [ "$executing" = true ] && exec_now=true
    approved=false; grep -qi '^## Approved' "$f" && approved=true
    awaiting=false; [ "$status" = BLOCKED ] && awaiting=true
    dep="$(task_dep "$f")"
    if [ -n "$dep" ]; then
      if [ -f "$TASKS/$dep" ] && [ "$(task_status "$TASKS/$dep")" = DONE ]; then depstatus='"done"'; else depstatus='"pending"'; fi
      dep="\"$(json_escape "$dep")\""
    else
      dep=null; depstatus=null
    fi
    printf '%s{"file":"%s","status":"%s","current":%s,"next":%s,"executing":%s,"approved":%s,"awaiting_answer":%s,"depends_on":%s,"dep_status":%s}' \
      "$sep" "$(json_escape "${f##*/}")" "$status" "$current" "$next" "$exec_now" "$approved" "$awaiting" "$dep" "$depstatus"
    sep=","
  done
  printf ']\n'
}

# Internal: the lines fzf consumes (STATUS<space>filename), FIFO order.
cmd_list() {
  local f
  for f in "$TASKS"/*.task.md; do printf '%-7s %s\n' "$(task_status "$f")" "${f##*/}"; done
}

# The ONE task the executor should act on this cycle — prints its filename, or
# nothing. Deterministic selection lives here (not in the executor's judgement):
#   0. if the tree is dirty, a finished task is awaiting `mux ok` → idle (nothing)
#   1. a RUNNING task wins (resume it) — enforces one-at-a-time
#   2. else the FIFO-first READY task whose # Depends-on: is DONE (or absent)
#   3. else nothing
cmd_next() {
  git_clean || return 0      # work pending the human's approval — don't grab more
  local f dep
  for f in "$TASKS"/*.task.md; do
    [ "$(task_status "$f")" = RUNNING ] && { printf '%s\n' "${f##*/}"; return 0; }
  done
  for f in "$TASKS"/*.task.md; do          # FIFO by filename
    [ "$(task_status "$f")" = READY ] || continue
    dep="$(task_dep "$f")"
    if [ -n "$dep" ]; then
      [ -f "$TASKS/$dep" ] && [ "$(task_status "$TASKS/$dep")" = DONE ] || continue
    fi
    printf '%s\n' "${f##*/}"; return 0
  done
}

# Interactive terminal board: live list + preview + verb keybindings.
cmd_board() {
  command -v fzf >/dev/null 2>&1 || die "mux board needs fzf (e.g. brew install fzf). Plain board:  mux status"
  local self; self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  cmd_list | fzf \
    --header $'↵ show · ctrl-r release · ctrl-o approve · esc quit' \
    --preview "bash \"$self\" show {2}" \
    --preview-window 'right,62%,wrap' \
    --bind "ctrl-r:execute-silent(bash \"$self\" release {2})+reload(bash \"$self\" _list)" \
    --bind "ctrl-o:execute-silent(bash \"$self\" ok)+reload(bash \"$self\" _list)" \
    --bind "enter:execute(bash \"$self\" show {2} | ${PAGER:-less})" \
    >/dev/null || true
}

# --- session launchers (the only verbs that start a Claude session) ---------

cmd_planner() {
  local name="${1:-planner}"
  echo "◆ PLANNER (producer): ${name}"
  echo "  reads your code; may write ONLY under .mux/ — cannot touch source"
  echo "  writes tasks to .mux/tasks/<timestamp>-<slug>.task.md as DRAFT"
  echo "  YOU flip them to READY (mux release <id>); executor runs READY oldest-first"
  echo "  see the queue any time:  mux status"
  echo
  # Per-session scoped permissions: ignore project settings so a broad project
  # allow-rule can't widen write scope; pre-approve writes under .mux only, so
  # any OTHER write prompts (a stray code edit can't happen silently).
  # NOTE: pattern is .mux/** with NO leading ./ — Claude Code normalizes paths
  # to project-root-relative, and a "./" prefix makes the rule fail to match.
  exec claude \
    -n "planner:${name}" \
    --setting-sources user \
    --permission-mode default \
    --allowedTools 'Read' 'Glob' 'Grep' 'Bash' 'Write(.mux/**)' 'Edit(.mux/**)' \
    --append-system-prompt "$(sed "s/__NAME__/${name}/g" "$PROMPTS_DIR/PLANNER.md")"
}

# What Claude is told to do each headless cycle (one task unit, then exit).
executor_cycle() {
  cat <<'CYCLE'
You are a headless worker with NO memory between runs. Run `mux next` (bash): it prints the ONE task file to work on, or nothing.
- If it prints nothing, do NOTHING and stop.
- Otherwise, if that task is not already RUNNING, claim it with `mux claim <task>`. Then COMPLETE THE ENTIRE TASK in THIS session: do everything its Goal and Details require and run the tests it names. Do NOT stop early or leave it half-done — there is no shared memory between runs, so if you stop, the next run starts over from scratch and makes no progress. Keep working until the task is fully done.
- NEVER run git and NEVER commit — mux handles that. When the work is fully complete, STOP and leave the task RUNNING; the human reviews your changes and runs `mux ok` to commit them (or discards them).
- You are headless — there is no one to ask. ONLY if you genuinely cannot proceed without a human decision, run `mux block <task> "<your question>"` and stop.
- If the task is truly unworkable, run `mux fail <task> "<one-line reason>"` and stop.
CYCLE
}

# Seconds for a sleep interval like 5m / 30s / 1h (macOS sleep needs seconds).
to_seconds() { case "$1" in *h) echo $(( ${1%h} * 3600 ));; *m) echo $(( ${1%m} * 60 ));; *s) echo "${1%s}";; *) echo "$1";; esac; }

# ONE headless cycle: claude -p (no input channel = unpromptable), output
# streamed live to a per-tick log the UI can tail. Subscription, not API key.
cmd_tick() {
  mkdir -p .mux/log
  mkdir .mux/tick.lock 2>/dev/null || { echo "· tick: one already running, skipped"; return 0; }
  local log=.mux/log/executor.jsonl        # ONE rolling log — never blanks between tasks
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude -p "$(executor_cycle)" \
    --dangerously-skip-permissions \
    --verbose --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPTS_DIR/EXECUTOR.md")" >> "$log" 2>&1 || true
  rmdir .mux/tick.lock 2>/dev/null || true
  [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 4000 ] && { tail -n 2000 "$log" > "$log.tmp" && mv "$log.tmp" "$log"; } || true
}

# Headless loop: poll for work; spend a model run ONLY when a task is runnable.
# No session, nothing to reprompt. Usually started for you by `mux web`.
cmd_executor() {
  local human="${1:-10s}" secs; secs="$(to_seconds "$human")"
  rmdir .mux/tick.lock 2>/dev/null || true     # clear a stale lock from a killed tick
  echo "▶ executor — headless; polls for work every ${human}, runs a cycle only when there is some."
  while :; do
    [ -n "$(cmd_next)" ] && cmd_tick
    sleep "$secs"
  done
}

# Stop the executor loop + web server recorded for THIS repo (only ours — we
# verify the pid is still a mux/python process, never kill a recycled pid).
cmd_stop() {
  local run=.mux/run pid name stopped=0
  for name in web executor; do
    pid="$(cat "$run/$name.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -qE 'server\.py|mux\.sh'; then
      kill "$pid" 2>/dev/null && { echo "■ stopped $name (pid $pid)"; stopped=1; }
    fi
    rm -f "$run/$name.pid"
  done
  rmdir .mux/tick.lock 2>/dev/null || true
  [ "$stopped" -eq 1 ] || echo "nothing to stop"
}

cmd_web() {
  command -v python3 >/dev/null 2>&1 || die "mux web needs python3"
  local port="${1:-8770}"   # NOT 7000 — macOS AirPlay Receiver squats on 7000
  mkdir -p .mux/log .mux/run
  cmd_stop >/dev/null 2>&1                 # clean up any previous mux web for this repo
  cmd_executor "${2:-10s}" >> .mux/log/executor.loop 2>&1 &
  local epid=$!; echo "$epid" > .mux/run/executor.pid
  MUX_REPO="$REPO_ROOT" MUX_BIN="$SELF_DIR/mux.sh" MUX_PORT="$port" python3 "$SELF_DIR/server.py" &
  local wpid=$!; echo "$wpid" > .mux/run/web.pid
  trap 'kill "$epid" "$wpid" 2>/dev/null; rm -f "$REPO_ROOT"/.mux/run/*.pid; rmdir "$REPO_ROOT/.mux/tick.lock" 2>/dev/null' EXIT INT TERM
  echo "▶ mux web → http://127.0.0.1:$port    (Ctrl-C stops UI + executor; or run: mux stop)"
  # Pop the browser once the server is listening, unless told not to (MUX_NO_OPEN=1).
  if [ -z "${MUX_NO_OPEN:-}" ]; then
    local opener=""; command -v open >/dev/null 2>&1 && opener=open || { command -v xdg-open >/dev/null 2>&1 && opener=xdg-open; }
    [ -n "$opener" ] && ( sleep 0.6; "$opener" "http://127.0.0.1:$port" ) >/dev/null 2>&1 &
  fi
  wait "$wpid"
}

cmd_help() { sed -n '2,/^$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; }

# --- dispatch --------------------------------------------------------------

cmd="${1:-status}"; shift || true
case "$cmd" in
  add)            cmd_add "$@" ;;
  release)        cmd_release "$@" ;;
  claim)          cmd_claim "$@" ;;
  start|web)      cmd_web "$@" ;;
  block)          cmd_block "$@" ;;
  resolve)        cmd_resolve "$@" ;;
  fail)           cmd_fail "$@" ;;
  revert)         cmd_revert "$@" ;;
  ok)             cmd_ok "$@" ;;
  changes)        cmd_changes "$@" ;;
  show)           cmd_show "$@" ;;
  ls|status)      cmd_status "$@" ;;
  board)          cmd_board "$@" ;;
  next)           cmd_next "$@" ;;
  _list)          cmd_list "$@" ;;
  planner)        cmd_planner "$@" ;;
  executor)       cmd_executor "$@" ;;
  tick)           cmd_tick "$@" ;;
  stop)           cmd_stop "$@" ;;
  help|-h|--help) cmd_help ;;
  *)              die "unknown verb '$cmd' — try:  mux help" ;;
esac

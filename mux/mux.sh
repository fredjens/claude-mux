#!/usr/bin/env bash
# mux.sh — the VERB LAYER: the only sanctioned way to change a task's state.
#
# Every legal move in the workflow is one subcommand here. Nothing else should
# hand-edit a task's STATUS — you, a hook, the output tick, or a future UI all
# go through these verbs, so the rules (a DRAFT can't commit, a RUNNING task
# can't be released, etc.) live in ONE place and illegal moves are refused.
#
# Source of truth stays the files in .mux/tasks/*.task.md. These verbs only do
# validated edits to those files; git (committing on `ok`) is the output's job.
#
#   mux channel  [name]         open a channel (reads repo, writes only .mux/)
#   mux start    [branch] [port]  open a session: pick/create the branch, then
#                               the web view + output loop (default :8770). With
#                               no args on a fresh start (clean tree, all pushed,
#                               nothing RUNNING) it PROMPTS for the branch; with
#                               in-flight work it silently continues. `mux start
#                               <branch>` is non-interactive; `--new` forces the
#                               prompt; a numeric first arg is still the port.
#   mux web      [branch] [port]  alias of `mux start`
#   mux stop                    stop this repo's web UI + output loop
#   mux output [interval]     headless output loop on its own (web starts this for you)
#   mux tick                    run ONE headless cycle (for launchd/cron)
#   mux add  <slug> [goal...]   create a DRAFT task
#   mux ls | status             the board
#   mux status --json           machine-readable board (for fzf/Raycast/UIs)
#   mux board                   interactive board (fzf): preview + verb keys
#   mux next                    the one task the output should run now
#   mux show     <id>           print a task file
#   mux release  <id>           DRAFT  -> READY   (you release it to run)
#   mux unrelease <id>          READY  -> DRAFT   (regret it before it starts)
#   mux claim    <id>           READY  -> RUNNING (output claims it; not for you)
#                               (in auto mode the executor also claims DRAFTs in
#                               place — no DRAFT->READY rewrite)
#   mux block    <id> <q...>    RUNNING-> BLOCKED (park with a question)
#   mux resolve  <id> [a...]    BLOCKED-> READY   (answer + re-queue)
#   mux ok       [note...]      approve RUNNING: commit -> COMMITTED (awaiting push)
#   mux end                     END the session: push the branch, clear COMMITTED
#                               tasks, return to base, stop the loop + web UI
#   mux changes  <note...>      ask the RUNNING task for a revision (stays RUNNING)
#   mux revert                  reject RUNNING: discard the changes -> FAILED
#   mux fail     <id> <why...>  RUNNING-> FAILED  (output: discard + reason)
#   mux delete   <id>           remove a DRAFT/FAILED/COMMITTED task file (clear it off the board)
#   mux help
#
# <id> is any unique substring of a task's filename (usually its slug).
#
# Recovery — a tick killed mid-cycle (e.g. `mux stop` while it was working):
#   its RUNNING task is flagged "(interrupted — revert & re-release)" in
#   `mux status` because the working tree holds PARTIAL, half-finished edits.
#   Do NOT `mux ok` it (that would commit incomplete work). Instead:
#     mux revert            discard the partial edits → FAILED, clean tree again
#   then re-release it to run fresh: re-add the task (`mux add` + `mux release`)
#   so the output retries it from scratch — never `mux ok` an interrupted task.

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
# The one rolling output tick log (claude stream-json). Defined once so helpers
# like session_from_log read the same path cmd_tick writes to.
LOG=.mux/log/output.jsonl
# Append-only ledger of approved (committed, then deleted) task filenames, so a
# `# Depends-on:` pointing at a deleted task still resolves. Lives under .mux,
# so it's never committed (cmd_ok does `git reset -q -- .mux`).
DONE_LOG=.mux/done.log
# Auto mode flag — the dashboard's "Auto mode" toggle persists as the EXISTENCE
# of this file (mirrors server.py's auto_enabled). When ON the executor runs
# DRAFT tasks IN PLACE (no DRAFT→READY rewrite) and the dashboard auto-approves
# each finish, so the queue flows hands-off. Because nothing on disk is mutated,
# toggling OFF leaves every task's status exactly as it was — the Release/Approve
# buttons simply reappear.
AUTO_FLAG=.mux/auto

# --- helpers ---------------------------------------------------------------

auto_on() { [ -f "$AUTO_FLAG" ]; }

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
task_session() { grep -m1 -i '^# Session:' "$1" | sed 's/.*Session:[[:space:]]*//' | awk '{print $1}' || true; }
# The planner (channel) session id that authored this task; lets `direct ⇥`
# resume that exact planning conversation (separate from the output's # Session:).
task_channel() { grep -m1 -i '^# Channel:' "$1" | sed 's/.*Channel:[[:space:]]*//' | awk '{print $1}' || true; }
# The short SHA recorded on a COMMITTED task (empty until `mux ok` writes it).
task_commit() { grep -m1 -i '^# Commit:' "$1" | sed 's/.*Commit:[[:space:]]*//' | awk '{print $1}' || true; }

# Is a dependency satisfied? $1 = the dependency's task filename. A committed
# task's work IS committed, so a lingering COMMITTED (or DONE) file satisfies it;
# once pushed and removed the done.log ledger keeps it satisfied.
dep_is_done() {
  if [ -f "$TASKS/$1" ]; then
    case "$(task_status "$TASKS/$1")" in DONE|COMMITTED) return 0 ;; esac
  fi
  [ -f "$DONE_LOG" ] && grep -qxF -- "$1" <(cut -f1 "$DONE_LOG") && return 0
  return 1
}

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
# The subject is `slug: <first Goal line>`; the body carries the REST of the
# Goal block (a short summary of the plan, stopping at the next ## heading),
# then `task: <filename>`, then the optional approve note. Goal is meant to be
# short, so this stays tidy — Details is never included.
commit_message() {
  local f="$1" note="${2:-}" stat="${3:-}" slug goal_first goal_rest
  slug="$(grep -m1 -i '^# Task:' "$f" | sed 's/^# *[Tt]ask:[[:space:]]*//')"
  # The Goal block: every line between "## Goal" and the next "##" heading,
  # dropping leading/trailing blank lines. The first such line is the subject;
  # the rest is the body summary. Details is deliberately never included.
  goal_first="$(awk '/^## *Goal/{g=1;next} /^##/{g=0} g&&NF{print;exit}' "$f")"
  goal_rest="$(awk '
    /^## *Goal/{g=1;next} /^##/{g=0; next}
    g{ if(!seen){ if(NF){seen=1}; next } if(NF){last=NR} lines[NR]=$0 }
    END{ for(i=1;i<=last;i++) if(i in lines) print lines[i] }
  ' "$f")"
  printf '%s: %s\n' "${slug:-task}" "${goal_first:-see task file}"
  [ -n "$goal_rest" ] && printf '\n%s\n' "$goal_rest"
  printf '\ntask: %s' "${f##*/}"
  [ -n "$note" ] && printf '\n\n%s' "$note"
  [ -n "$stat" ] && printf '\n\n%s' "$stat"
  return 0
}

# Resolve a unique task file from a filename substring.
resolve_id() {
  local q="${1%.task.md}"                       # tolerate a full filename
  local matches=( "$TASKS"/*"$q"*.task.md )
  [ ${#matches[@]} -gt 0 ] || die "no task matches '$1' — if it was approved, its file is gone; try: git log --grep $q"
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

# Annotate the single RUNNING task as interrupted mid-tick (called only when a
# live tick is actually killed). Like running_task but QUIET: a stop with no
# RUNNING task — or, defensively, more than one — is normal here, so do nothing
# and never die. The marker is an annotation; STATUS stays RUNNING (the
# work-in-tree invariant is unchanged). Idempotent — never doubles the line.
mark_interrupted() {
  local f found="" n=0
  for f in "$TASKS"/*.task.md; do
    if [ "$(task_status "$f")" = RUNNING ]; then found="$f"; n=$((n+1)); fi
  done
  [ "$n" -eq 1 ] || return 0
  grep -qi '^# Interrupted:' "$found" || append_block "$found" "# Interrupted: $(stamp)"
}

# The current tick's claude session id, read from the live rolling log (the
# `init` event emits it at the very start of a tick, long before any tool call).
# Lets block/fail pin the session WHILE the tick is still running — see below.
session_from_log() {
  grep -o '"session_id":"[0-9a-f-]\{36\}"' "$LOG" 2>/dev/null \
    | tail -n1 | sed 's/.*"session_id":"\(.*\)"/\1/'
}

# REPLACE any prior `# Session:` line on a specific task file with this id, so a
# stuck task can be resumed/chatted interactively later (the rolling log tail
# won't still hold it). A task can be ticked more than once; keep only the latest
# id. The id is validated to look like a session id so a stray log line can't
# poison the file; a non-id (or empty) is a silent no-op.
pin_session() {
  local f="$1" id="$2"
  printf '%s' "$id" | grep -Eqi '^[0-9a-f-]{36}$' || return 0
  grep -vi '^# Session:' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  append_block "$f" "# Session: $id"
}

# Pin a tick's session id onto the single RUNNING task, after the tick ends.
# Defensive like mark_interrupted: act only when exactly one task is RUNNING,
# never error. This covers a task left RUNNING (awaiting approval); a task that
# blocked/failed mid-tick is no longer RUNNING here, so block/fail pin it
# themselves at transition time (via session_from_log) instead.
record_session() {
  local id="$1" f found="" n=0
  printf '%s' "$id" | grep -Eqi '^[0-9a-f-]{36}$' || return 0
  for f in "$TASKS"/*.task.md; do
    if [ "$(task_status "$f")" = RUNNING ]; then found="$f"; n=$((n+1)); fi
  done
  [ "$n" -eq 1 ] || return 0
  pin_session "$found" "$id"
}

# The branch to return to when a session ends. Explicit MUX_BASE wins, then a
# .mux/base note (recorded at session start, e.g. by session-start-branch), else
# the remote's default branch (origin/HEAD), else "main".
resolve_base() {
  if [ -n "${MUX_BASE:-}" ]; then printf '%s\n' "$MUX_BASE"; return; fi
  if [ -f .mux/base ]; then
    local b; b="$(head -n1 .mux/base 2>/dev/null | tr -d '[:space:]')"
    [ -n "$b" ] && { printf '%s\n' "$b"; return; }
  fi
  local d; d="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -n "$d" ] && { printf '%s\n' "$d"; return; }
  printf 'main\n'
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

# Regret a release before the output claims it: READY -> DRAFT. The inverse of
# cmd_release, so a task can be pulled back off the queue and edited. Guarded to
# READY only — you can't unrelease something already RUNNING/DONE/etc.
cmd_unrelease() {
  [ $# -ge 1 ] || die "usage: mux unrelease <id>"
  local f; f="$(resolve_id "$1")"
  require_status "$f" READY
  set_status "$f" DRAFT
  echo "← ${f##*/}  READY → DRAFT"
}

cmd_block() {
  [ $# -ge 2 ] || die "usage: mux block <id> <question...>"
  local f; f="$(resolve_id "$1")"; shift
  require_status "$f" RUNNING
  set_status "$f" BLOCKED
  append_block "$f" "## Question ($(stamp))
$*"
  # Pin the live tick's session NOW: after the tick ends this task is no longer
  # RUNNING, so record_session would skip it — leaving a blocked task with no
  # session to chat/resume, exactly when you most want one.
  pin_session "$f" "$(session_from_log)"
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
  local f st; f="$(resolve_id "$1")"; st="$(task_status "$f")"
  # The output claims a READY task → RUNNING. In auto mode it also claims DRAFTs
  # in place (no DRAFT→READY rewrite first), so toggling auto off leaves un-run
  # tasks DRAFT with their Release button intact.
  [ "$st" = READY ] || { auto_on && [ "$st" = DRAFT ]; } \
    || die "${f##*/} is $st — claim expects READY (DRAFT too, in auto mode) — refused"
  git_clean || die "working tree not clean — commit or stash your own changes first"
  set_status "$f" RUNNING
  echo "▶ ${f##*/}  $st → RUNNING   (on $(git branch --show-current 2>/dev/null || echo '?'))"
}

# Throw away all uncommitted work EXCEPT the .mux queue. Safe because the
# output always starts from a clean tree — anything dirty is this task's work.
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
  # Same as cmd_block: pin the live tick's session before the tick ends, so a
  # self-failed task is still resumable (record_session would skip it post-tick).
  pin_session "$f" "$(session_from_log)"
  echo "✗ ${f##*/}  RUNNING → FAILED  (changes discarded)"
}

# Human rejects the finished work: discard the output's changes, mark FAILED.
cmd_revert() {
  local f; f="$(running_task)"
  discard_changes
  set_status "$f" FAILED
  append_block "$f" "# Reverted: $(stamp)${*:+ — $*}"
  echo "↩ ${f##*/} reverted — changes discarded, marked FAILED"
}

# Permanently remove a dead task file so it stops cluttering the board. Only a
# FAILED task may be deleted — its changes are already discarded, so there is
# nothing left to lose; any other state must go through the lifecycle first.
# Delete a task file outright. Allowed only from a state with nothing to lose:
# DRAFT (never ran), FAILED (already discarded), COMMITTED (work is already
# committed and in done.log — an escape hatch to clear it off the board by hand
# when you pushed elsewhere), or BLOCKED (parked on a question you've decided not
# to answer). A READY/RUNNING task is refused — unrelease/revert/fail it first.
# A BLOCKED task can still hold its own partial edits in the tree; refuse then so
# delete can't silently nuke uncommitted work (revert/resolve it instead). A
# clean tree means nothing to lose, so it's safe.
cmd_delete() {
  [ $# -ge 1 ] || die "usage: mux delete <id>"
  local f st; f="$(resolve_id "$1")"; st="$(task_status "$f")"
  case "$st" in
    DRAFT|FAILED|COMMITTED) ;;
    BLOCKED) git_clean || die "${f##*/} is BLOCKED with uncommitted changes — revert or resolve it first" ;;
    *) die "${f##*/} is $st — only a DRAFT, FAILED, COMMITTED, or BLOCKED task can be deleted" ;;
  esac
  rm -f "$f"
  echo "🗑 ${f##*/} deleted"
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
  # Diffstat of exactly what's staged (the .mux queue excluded above), so the
  # commit message is self-describing in `git log` without opening the diff.
  local stat; stat="$(git diff --cached --stat -- . ':(exclude).mux' 2>/dev/null)"
  git commit -q -m "$(commit_message "$f" "$*" "$stat")" || die "git commit failed"
  local sha br; sha="$(git rev-parse --short HEAD)"; br="$(git branch --show-current 2>/dev/null || echo '?')"
  # The commit is now the permanent record. Note it in the done.log ledger (so a
  # `# Depends-on:` on this task still resolves even after the file is finally
  # removed at push), then transition the task IN PLACE to COMMITTED — it lingers
  # on the board as "committed, not yet pushed" until a later push clears it. The
  # working tree is now clean, so cmd_next flows on and COMMITTED never gates it.
  printf '%s\t%s\t%s\n' "${f##*/}" "$sha" "$(stamp)" >> "$DONE_LOG"
  set_status "$f" COMMITTED
  append_block "$f" "# Commit: $sha
# Branch: $br"
  echo "✓ ${f##*/} committed ($sha on $br) — awaiting push"
}

# End & push: FINALIZE the session. Push the current branch to its upstream,
# clear the COMMITTED tasks it shipped, return to the base branch, and tear the
# loop + web UI down. This is how you END a session — the outward-facing
# counterpart to `mux stop` (which only halts the loop/UI and leaves the branch,
# its commits, and the queue untouched so the session can resume later).
cmd_end() {
  # Refuse while un-reviewed work exists: a RUNNING task or a tree dirty outside
  # .mux must be resolved (approve/revert) first — `end` only ships already-
  # COMMITTED work, never half-finished edits.
  local f
  for f in "$TASKS"/*.task.md; do
    [ "$(task_status "$f")" = RUNNING ] && die "a task is still RUNNING — approve or revert the running task before ending the session"
  done
  git_clean || die "working tree not clean outside .mux — approve or revert the running task before ending the session"

  local branch base; branch="$(git branch --show-current 2>/dev/null || true)"
  [ -n "$branch" ] || die "detached HEAD — checkout a branch before ending the session"
  base="$(resolve_base)"

  # Push outward — NEVER force, never switch-to-push. Use the existing upstream
  # if set, otherwise establish one. On ANY failure (auth, non-fast-forward)
  # leave the WHOLE session intact: clear nothing, don't checkout away, exit
  # non-zero so the user can fix the error above and retry. (An "everything
  # up-to-date" push is a harmless success — no commits to push still ends.)
  echo "↑ pushing $branch …"
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git push || die "push failed — session left intact; fix the error above and retry"
  else
    git push -u origin HEAD || die "push failed — session left intact; fix the error above and retry"
  fi

  # Push succeeded — the COMMITTED tasks are now pushed. Their work is already in
  # done.log, so remove the files to clear them off the board.
  local cleared=0 st
  for f in "$TASKS"/*.task.md; do
    st="$(task_status "$f")"
    [ "$st" = COMMITTED ] && { rm -f "$f"; cleared=$((cleared+1)); }
  done
  echo "✓ pushed $branch — cleared $cleared committed task(s)"
  echo "↳ wiped local mux state (.mux/)"

  # Return to the base branch (a dirty .mux/ queue never blocks the checkout).
  if [ "$branch" != "$base" ]; then
    if git checkout "$base" 2>/dev/null; then echo "↳ back on $base"
    else echo "⚠ could not checkout $base — staying on $branch"; fi
  fi

  # Tear this repo's loop + web UI down (same machinery as `mux stop`).
  cmd_stop

  # Wipe ALL local mux working state so the next session on this checkout starts
  # clean — no carried-over transcript/history, no stale NOTES.md, no leftover
  # queue. .mux/ is gitignored, so a branch switch never touches it; only Ship
  # resets it. This runs LAST, AFTER cmd_stop has read its pid files in
  # .mux/run/, and ONLY on a successful push (the `die` calls above abort first
  # on push failure, leaving .mux/ intact for retry). mux recreates the subdirs
  # it needs lazily on the next run (cmd_tick mkdir -p .mux/log .mux/run,
  # record_base mkdir -p .mux, the task queue on add/session start). Path is
  # absolute via $REPO_ROOT — never depend on cwd. cmd_stop (the `stop` verb) is
  # intentionally left non-destructive so a paused session can resume.
  rm -rf "$REPO_ROOT/.mux"
}

cmd_changes() {
  [ $# -ge 1 ] || die "usage: mux changes <note...>"
  local f; f="$(running_task)"
  append_block "$f" "## Change request ($(stamp))
$*"
  echo "↻ ${f##*/} — revision requested; stays RUNNING, output revises next tick"
}

cmd_show() {
  [ $# -ge 1 ] || die "usage: mux show <id>"
  cat "$(resolve_id "$1")"
}

cmd_status() {
  [ "${1:-}" = "--json" ] && { cmd_status_json; return; }
  local tasks=( "$TASKS"/*.task.md )
  [ ${#tasks[@]} -gt 0 ] || { echo "no tasks yet — open a channel:  mux channel"; return 0; }
  printf '%-3s %-7s %s\n' "" "STATUS" "TASK"
  printf '%-3s %-7s %s\n' "" "------" "----"
  local f status marker dep depstatus note next_marked=0
  # The interrupted marker is only LIVE while the tree is dirty (a resumed,
  # finished task has a clean tree, so the stale annotation is ignored).
  local dirty=false; git_clean || dirty=true
  for f in "${tasks[@]}"; do          # filename sort == FIFO
    status="$(task_status "$f")"
    marker="   "
    if [ "$status" = RUNNING ]; then marker=" * "; next_marked=1
    elif [ "$status" = READY ] && [ "$next_marked" -eq 0 ]; then marker=" > "; next_marked=1
    fi
    note=""
    if [ "$status" = RUNNING ] && [ "$dirty" = true ] && grep -qi '^# Interrupted:' "$f"; then
      note=" (interrupted — revert & re-release)"
    fi
    grep -qi '^## Approved' "$f" && note="$note (approved)"
    [ "$status" = BLOCKED ] && note=" (awaiting answer)"
    if [ "$status" = COMMITTED ]; then
      local sha; sha="$(task_commit "$f")"
      note=" (committed${sha:+ $sha} — awaiting push)"
    fi
    dep="$(task_dep "$f")"
    if [ -n "$dep" ]; then
      depstatus=pending
      dep_is_done "$dep" && depstatus=done
      note="$note (depends: ${dep%%.task.md} [$depstatus])"
    fi
    printf '%s %-7s %s%s\n' "$marker" "$status" "${f##*/}" "$note"
  done
  echo
  echo " *  = RUNNING / awaiting you (loop holds this task; BLOCKED ones don't gate)"
  echo " >  = next READY task the output will pick"
}

# The board as JSON — one source of truth for every UI (fzf, Raycast, web...).
cmd_status_json() {
  local tasks=( "$TASKS"/*.task.md )
  [ ${#tasks[@]} -gt 0 ] || { printf '[]\n'; return 0; }
  local f status dep depstatus approved awaiting current next exec_now interrupted session commit next_marked=0 sep=""
  local executing=false; [ -d .mux/tick.lock ] && executing=true
  # Interrupted is live only while the tree is dirty (see cmd_status).
  local dirty=false; git_clean || dirty=true
  printf '['
  for f in "${tasks[@]}"; do
    status="$(task_status "$f")"
    current=false; next=false
    if [ "$status" = RUNNING ]; then current=true; next_marked=1
    elif [ "$status" = READY ] && [ "$next_marked" -eq 0 ]; then next=true; next_marked=1
    fi
    exec_now=false; [ "$status" = RUNNING ] && [ "$executing" = true ] && exec_now=true
    interrupted=false; [ "$status" = RUNNING ] && [ "$dirty" = true ] && grep -qi '^# Interrupted:' "$f" && interrupted=true
    approved=false; grep -qi '^## Approved' "$f" && approved=true
    awaiting=false; [ "$status" = BLOCKED ] && awaiting=true
    dep="$(task_dep "$f")"
    if [ -n "$dep" ]; then
      if dep_is_done "$dep"; then depstatus='"done"'; else depstatus='"pending"'; fi
      dep="\"$(json_escape "$dep")\""
    else
      dep=null; depstatus=null
    fi
    session="$(task_session "$f")"
    if [ -n "$session" ]; then session="\"$(json_escape "$session")\""; else session=null; fi
    commit="$(task_commit "$f")"
    if [ -n "$commit" ]; then commit="\"$(json_escape "$commit")\""; else commit=null; fi
    printf '%s{"file":"%s","status":"%s","current":%s,"next":%s,"executing":%s,"interrupted":%s,"approved":%s,"awaiting_answer":%s,"depends_on":%s,"dep_status":%s,"session":%s,"commit":%s}' \
      "$sep" "$(json_escape "${f##*/}")" "$status" "$current" "$next" "$exec_now" "$interrupted" "$approved" "$awaiting" "$dep" "$depstatus" "$session" "$commit"
    sep=","
  done
  printf ']\n'
}

# Internal: the lines fzf consumes (STATUS<space>filename), FIFO order.
cmd_list() {
  local f
  for f in "$TASKS"/*.task.md; do printf '%-7s %s\n' "$(task_status "$f")" "${f##*/}"; done
}

# The ONE task the output should act on this cycle — prints its filename, or
# nothing. Deterministic selection lives here (not in the output's judgement):
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
  local st
  for f in "$TASKS"/*.task.md; do          # FIFO by filename
    st="$(task_status "$f")"
    # READY is always runnable; in auto mode a DRAFT is too (run in place).
    [ "$st" = READY ] || { auto_on && [ "$st" = DRAFT ]; } || continue
    dep="$(task_dep "$f")"
    if [ -n "$dep" ]; then
      dep_is_done "$dep" || continue
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

cmd_channel() {
  local name="${1:-channel}"
  echo "◆ CHANNEL (producer): ${name}"
  echo "  reads your code; may write ONLY under .mux/ — cannot touch source"
  echo "  writes tasks to .mux/tasks/<timestamp>-<slug>.task.md as DRAFT"
  echo "  YOU flip them to READY (mux release <id>); output runs READY oldest-first"
  echo "  see the queue any time:  mux status"
  echo
  # Mint a fixed session id for this planner so a later `direct ⇥` can
  # --resume THIS exact conversation. Lower-cased to match the [0-9a-f-]{36}
  # validation used elsewhere. We inject it into the CHANNEL prompt (the
  # __SESSION__ placeholder) so the channel stamps it onto every task it writes.
  local sid; sid="$(uuidgen | tr 'A-Z' 'a-z')"
  # Per-session scoped permissions: ignore project settings so a broad project
  # allow-rule can't widen write scope; pre-approve writes under .mux only, so
  # any OTHER write prompts (a stray code edit can't happen silently).
  # NOTE: pattern is .mux/** with NO leading ./ — Claude Code normalizes paths
  # to project-root-relative, and a "./" prefix makes the rule fail to match.
  exec claude \
    -n "channel:${name}" \
    --session-id "$sid" \
    --setting-sources user \
    --permission-mode default \
    --allowedTools 'Read' 'Glob' 'Grep' 'Bash' 'Write(.mux/**)' 'Edit(.mux/**)' \
    --append-system-prompt "$(sed -e "s/__NAME__/${name}/g" -e "s/__SESSION__/${sid}/g" "$PROMPTS_DIR/CHANNEL.md")"
}

# What Claude is told to do each headless cycle (one task unit, then exit).
output_cycle() {
  cat <<'CYCLE'
You are a headless worker with NO in-session memory between runs (each cycle is a fresh process), but `.mux/NOTES.md` carries durable execution notes forward across cycles — read it at the start and append to it at the end (see the OUTPUT prompt). Run `mux next` (bash): it prints the ONE task file to work on, or nothing.
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
  mkdir -p .mux/log .mux/run
  mkdir .mux/tick.lock 2>/dev/null || { echo "· tick: one already running, skipped"; return 0; }
  local log="$LOG"                       # ONE rolling log — never blanks between tasks
  # Run claude in the BACKGROUND and record its pid (.mux/run/tick.pid) so a
  # stopper (kill_tick) can find and halt THIS tick's claude — otherwise the
  # grandchild outlives a `kill` of the loop and keeps editing the tree. We then
  # `wait` for that exact child and capture ITS status (the backgrounded
  # command's, not the script's $?), swallowing it: a killed claude must never
  # abort the loop (the old `|| true` semantics, preserved).
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude -p "$(output_cycle)" \
    --dangerously-skip-permissions \
    --verbose --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPTS_DIR/OUTPUT.md")" >> "$log" 2>&1 &
  local cpid=$!
  echo "$cpid" > .mux/run/tick.pid
  wait "$cpid" 2>/dev/null || true
  rm -f .mux/run/tick.pid
  # Pin the session id this tick used onto its RUNNING task (last one wins) so a
  # stuck task can be resumed interactively. Do this BEFORE dropping the lock.
  record_session "$(grep -o '"session_id":"[0-9a-f-]\{36\}"' "$log" 2>/dev/null | tail -n1 | sed 's/.*"session_id":"\(.*\)"/\1/')"
  rmdir .mux/tick.lock 2>/dev/null || true
  [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 4000 ] && { tail -n 2000 "$log" > "$log.tmp" && mv "$log.tmp" "$log"; } || true
}

# Headless loop: poll for work; spend a model run ONLY when a task is runnable.
# No session, nothing to reprompt. Usually started for you by `mux web`.
cmd_output() {
  local human="${1:-10s}" secs; secs="$(to_seconds "$human")"
  rmdir .mux/tick.lock 2>/dev/null || true     # clear a stale lock from a killed tick
  echo "▶ output — headless; polls for work every ${human}, runs a cycle only when there is some."
  while :; do
    [ -n "$(cmd_next)" ] && cmd_tick
    sleep "$secs"
  done
}

# Halt THIS repo's in-flight output tick: the `claude -p` child cmd_tick
# backgrounded (pid in .mux/run/tick.pid). The lock is cleared ONLY after that
# claude is confirmed gone — never before — so the lock can't disappear while
# the model is still editing the working tree. Defensive like cmd_stop: act only
# if the recorded pid is alive AND still a claude process, so a recycled pid
# (some unrelated process now holding that number) is never killed.
kill_tick() {
  local pid; pid="$(cat .mux/run/tick.pid 2>/dev/null || true)"
  if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q 'claude'; then
    kill "$pid" 2>/dev/null || true     # ask it to stop...
    local i=0                            # ...escalate to -9 only if it lingers
    while ps -p "$pid" -o command= 2>/dev/null | grep -q 'claude'; do
      i=$((i+1))
      [ "$i" -eq 10 ] && kill -9 "$pid" 2>/dev/null || true   # ~1s grace, then SIGKILL
      [ "$i" -ge 30 ] && break                                 # give up after ~3s
      sleep 0.1
    done
    # The tick was LIVE — its RUNNING task holds PARTIAL, half-finished edits.
    # Flag it so it can't be mistaken for finished work awaiting `mux ok`.
    mark_interrupted
  fi
  # Only now that the tick's claude is gone do we drop its pid + the lock.
  rm -f .mux/run/tick.pid
  rmdir .mux/tick.lock 2>/dev/null || true
}

# Stop the output loop + web server recorded for THIS repo (only ours — we
# verify the pid is still a mux/python process, never kill a recycled pid). The
# loop dies FIRST so it can't spawn a fresh tick, THEN we halt any in-flight one.
cmd_stop() {
  local run=.mux/run pid name stopped=0
  for name in web output; do
    pid="$(cat "$run/$name.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -qE 'server\.py|mux\.sh'; then
      kill "$pid" 2>/dev/null && { echo "■ stopped $name (pid $pid)"; stopped=1; }
    fi
    rm -f "$run/$name.pid"
  done
  kill_tick     # halt the in-flight tick, then (inside) clear the lock
  [ "$stopped" -eq 1 ] || echo "nothing to stop"
}

# Record the branch THIS session forked from, so `mux end` knows where to return
# (resolve_base reads it). One line under .mux/ — coordinated with cmd_end.
record_base() { mkdir -p .mux; printf '%s\n' "$1" > .mux/base; }

# Is there in-flight work that means a fresh `mux start` should silently CONTINUE
# on the current branch rather than pop the branch-choice prompt? True (0) when
# ANY of these hold — the ONLY three signals (DRAFT/READY tasks never count):
#   1. uncommitted changes outside .mux (dirty tree, via git_clean), or
#   2. unpushed commits — ahead of upstream if one is set, else commits on HEAD
#      not contained in the base/default branch, or
#   3. a task is currently RUNNING.
# False (1) only on a clean, fully-pushed, nothing-RUNNING slate (a fresh start),
# regardless of which branch you are on.
session_in_flight() {
  git_clean || return 0                                   # (1) dirty tree
  local f
  for f in "$TASKS"/*.task.md; do                         # (3) RUNNING task
    [ "$(task_status "$f")" = RUNNING ] && return 0
  done
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    local ahead; ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    [ "${ahead:-0}" -gt 0 ] && return 0                   # (2a) ahead of upstream
  else
    local base ref="" cand; base="$(resolve_base)"
    for cand in "$base" "origin/$base"; do
      git rev-parse --verify --quiet "$cand" >/dev/null 2>&1 && { ref="$cand"; break; }
    done
    if [ -n "$ref" ]; then
      local n; n="$(git rev-list --count "$ref..HEAD" 2>/dev/null || echo 0)"
      [ "${n:-0}" -gt 0 ] && return 0                      # (2b) unmerged into base
    fi
  fi
  return 1
}

# Non-interactive `mux start <branch>`: create-or-checkout the named branch.
start_checkout() {
  local name="$1" current; current="$(git branch --show-current 2>/dev/null || true)"
  [ "$name" = "$current" ] && { echo "▶ continuing on $current"; return; }
  if git show-ref --verify --quiet "refs/heads/$name"; then
    git checkout "$name" || die "could not checkout $name"
    echo "▶ on existing branch $name"
  else
    git check-ref-format "refs/heads/$name" >/dev/null 2>&1 || die "invalid branch name: $name"
    git checkout -b "$name" || die "could not create branch $name (off ${current:-HEAD})"
    record_base "$current"
    echo "✚ created branch $name (off ${current:-HEAD}) — session will commit here"
  fi
}

# Create (or continue) a NEW branch from the interactive prompt.
start_new_branch() {
  local nm="$1" base="$2"
  git check-ref-format "refs/heads/$nm" >/dev/null 2>&1 || die "invalid branch name: $nm"
  if git show-ref --verify --quiet "refs/heads/$nm"; then
    printf "branch '%s' already exists — continue on it instead? [Y/n] " "$nm"
    local a; IFS= read -r a || a=""
    case "$a" in [Nn]*) die "aborted — '$nm' exists; re-run mux start to choose again" ;; esac
    git checkout "$nm" || die "could not checkout $nm"
    echo "▶ on existing branch $nm"
  else
    git checkout -b "$nm" || die "could not create branch $nm"
    record_base "$base"
    echo "✚ created branch $nm (off $base) — session will commit here"
  fi
}

# Restore the terminal after the TUI: cursor back, main screen, echo on. Reads
# the saved stty from the $_MUX_STTY global (set by start_tui) so it works as a
# trap handler even when fired mid-pick (Ctrl-C). Always safe to call twice.
_tui_restore() {
  if [ -n "${_MUX_STTY:-}" ]; then stty "$_MUX_STTY" 2>/dev/null || stty echo 2>/dev/null
  else stty echo 2>/dev/null || true; fi
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
}

# The fresh-start branch selector: a full-screen, keyboard-driven TUI in pure
# bash (no external deps — this stays a portable shell script). Shown ONLY on a
# genuinely fresh start AND only when both stdin/stdout are TTYs (the caller
# gates that). Drives the alternate screen + hidden cursor and ALWAYS restores
# them via trap — even on Ctrl-C mid-pick the terminal is left clean.
#
# Keys: ↑/↓ and k/j move (wraparound); Enter selects; printable chars filter
# the existing-branch rows live (the two action rows stay pinned); Backspace
# edits the filter; Esc or q cancel (== continue on current, zero friction).
# Note: k, j and q are reserved for navigation/cancel, so they never enter the
# filter string (every other printable char does).
#
# Outcomes print the SAME phrases as start_checkout so downstream is unchanged:
#   continue → "▶ continuing on <branch>"
#   create   → "✚ created branch <name> (off <base>) …"  + writes .mux/base
#   existing → checkout + "▶ on branch <branch>"
start_tui() {
  local current; current="$(git branch --show-current 2>/dev/null || echo '?')"

  # Colors / attributes via tput (gated here — start_tui only runs under a TTY;
  # no raw escapes are written anywhere else).
  local C_RST C_DIM C_BOLD C_ACC C_SEL
  C_RST="$(tput sgr0   2>/dev/null || true)"
  C_DIM="$(tput dim    2>/dev/null || true)"
  C_BOLD="$(tput bold  2>/dev/null || true)"
  C_ACC="$(tput setaf 6 2>/dev/null || true)"                       # cyan accent
  C_SEL="$(tput setab 6 2>/dev/null || true)$(tput setaf 0 2>/dev/null || true)"  # highlight bar

  # Existing local branches (newest-committed first is overkill; refname order).
  local -a branches=(); local b
  while IFS= read -r b; do branches+=("$b"); done \
    < <(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

  # Context line: clean/dirty + commits ahead of upstream (if tracked).
  local dirty ahead=""
  if git_clean; then dirty="clean"; else dirty="dirty"; fi
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    local n; n="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] && ahead="  ·  ${n} ahead"
  fi

  # Terminal setup + guaranteed restore (trap covers normal exit, die, Ctrl-C).
  _MUX_STTY="$(stty -g 2>/dev/null || true)"
  tput smcup 2>/dev/null || true; tput civis 2>/dev/null || true; stty -echo 2>/dev/null || true
  trap '_tui_restore' EXIT
  trap '_tui_restore; trap - EXIT; exit 130' INT TERM HUP

  local rows_avail; rows_avail=$(( $(tput lines 2>/dev/null || echo 24) - 12 ))
  [ "$rows_avail" -lt 3 ] && rows_avail=3

  local filter="" hi=0 off=0 choice=""
  while :; do
    # Build the visible rows: two pinned action rows + filtered branches.
    local -a rkind=() rval=()
    rkind+=("continue"); rval+=("$current")
    rkind+=("create");   rval+=("")
    local lf; lf="$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')"
    for b in "${branches[@]}"; do
      if [ -z "$filter" ] || printf '%s' "$b" | tr '[:upper:]' '[:lower:]' | grep -qF -- "$lf"; then
        rkind+=("branch"); rval+=("$b")
      fi
    done
    local nrows=${#rkind[@]}
    [ "$hi" -ge "$nrows" ] && hi=$((nrows-1)); [ "$hi" -lt 0 ] && hi=0
    [ "$hi" -lt "$off" ] && off=$hi
    [ "$hi" -ge $((off+rows_avail)) ] && off=$((hi-rows_avail+1))

    # --- render ----------------------------------------------------------
    tput clear 2>/dev/null || true
    printf '%s%s   _ __ ___  _   ___  __%s\n'   "$C_ACC" "$C_BOLD" "$C_RST"
    printf '%s%s  | '"'"'_ \` _ \\| | | \\ \\/ /%s\n' "$C_ACC" "$C_BOLD" "$C_RST"
    printf '%s%s  | | | | | | |_| |>  < %s\n'   "$C_ACC" "$C_BOLD" "$C_RST"
    printf '%s%s  |_| |_| |_|\\__,_/_/\\_\\%s\n'  "$C_ACC" "$C_BOLD" "$C_RST"
    printf '%s   M U L T I P L E X E R%s\n'      "$C_DIM" "$C_RST"
    printf '\n'
    printf '%s  branch %s%s%s   ·   %s   tree%s\n' "$C_DIM" "$C_RST$C_BOLD" "$current" "$C_RST$C_DIM" "$dirty$ahead" "$C_RST"
    printf '%s  pick the branch for THIS session — everything you commit lands there%s\n' "$C_DIM" "$C_RST"
    printf '\n'

    local i label
    for ((i=off; i<nrows && i<off+rows_avail; i++)); do
      case "${rkind[i]}" in
        continue) label="▶ Continue on ${rval[i]}" ;;
        create)   label="✚ Create a new branch…" ;;
        branch)   label="⌖ ${rval[i]}"; [ "${rval[i]}" = "$current" ] && label="$label  (current)" ;;
      esac
      if [ "$i" -eq "$hi" ]; then printf '  %s %-56s%s\n' "$C_SEL" "$label" "$C_RST"
      else                        printf '    %s\n' "$label"; fi
    done

    printf '\n'
    if [ -n "$filter" ]; then printf '  %sfilter:%s %s_\n' "$C_DIM" "$C_RST" "$filter"
    else printf '  %s↑/↓ move · type to filter · Enter select · Esc/q cancel%s\n' "$C_DIM" "$C_RST"; fi

    # --- read one key ----------------------------------------------------
    local k; IFS= read -rsn1 k || k=""
    case "$k" in
      "")                                       # Enter
        choice="select"; break ;;
      $'\x1b')                                  # ESC — maybe an arrow sequence
        local rest=""; IFS= read -rsn2 -t 1 rest 2>/dev/null || rest=""
        case "$rest" in
          '[A'|'OA') hi=$(( (hi-1+nrows)%nrows )) ;;
          '[B'|'OB') hi=$(( (hi+1)%nrows )) ;;
          '')        choice="cancel"; break ;;  # bare Esc
          *) ;;                                 # other escapes ignored
        esac ;;
      k) hi=$(( (hi-1+nrows)%nrows )) ;;
      j) hi=$(( (hi+1)%nrows )) ;;
      q) choice="cancel"; break ;;
      $'\x7f'|$'\b') filter="${filter%?}" ;;    # Backspace
      *) case "$k" in [[:print:]]) filter="$filter$k"; hi=0 ;; esac ;;
    esac
  done

  # --- act on the choice (terminal restored first so prompts/echo work) ---
  local kind="${rkind[hi]}" val="${rval[hi]}"
  _tui_restore; trap - EXIT INT TERM HUP
  case "$choice" in
    cancel) echo "▶ continuing on $current" ;;
    select)
      case "$kind" in
        continue) echo "▶ continuing on $current" ;;
        create)
          printf "new branch name> "; local nm; IFS= read -r nm || nm=""
          nm="$(printf '%s' "$nm" | tr -d '[:space:]')"
          [ -n "$nm" ] || die "no branch name given — aborted"
          start_new_branch "$nm" "$current" ;;
        branch)
          if [ "$val" = "$current" ]; then echo "▶ continuing on $val"
          else git checkout "$val" || die "could not checkout $val"; echo "▶ on branch $val"; fi ;;
      esac ;;
  esac
}

# Periodic, in-place status line while a TTY session runs (Part of cmd_web).
# Blocks until $wpid (the web server — the lifecycle owner) dies, refreshing a
# single line every few seconds with: elapsed time, current branch, a task
# tally (DRAFT/READY/RUNNING/COMMITTED parsed from each `# STATUS:`), and
# whether the output loop is alive. TTY-only — the non-TTY path just `wait`s.
start_status_loop() {
  local wpid="$1" start now el mm ss cur opid alive
  local C_DIM C_RST C_ACC; C_DIM="$(tput dim 2>/dev/null || true)"
  C_RST="$(tput sgr0 2>/dev/null || true)"; C_ACC="$(tput setaf 6 2>/dev/null || true)"
  start="$(date +%s)"
  while kill -0 "$wpid" 2>/dev/null; do
    local draft=0 ready=0 running=0 committed=0 f st
    for f in "$TASKS"/*.task.md; do
      [ -e "$f" ] || continue
      st="$(task_status "$f")"
      case "$st" in
        DRAFT)     draft=$((draft+1)) ;;
        READY)     ready=$((ready+1)) ;;
        RUNNING)   running=$((running+1)) ;;
        COMMITTED) committed=$((committed+1)) ;;
      esac
    done
    cur="$(git branch --show-current 2>/dev/null || echo '?')"
    opid="$(cat .mux/run/output.pid 2>/dev/null || true)"
    if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then alive="up"; else alive="down"; fi
    now="$(date +%s)"; el=$((now-start)); mm=$((el/60)); ss=$((el%60))
    printf '\r%s%s  mux ⟳ %02d:%02d  ·  %s  ·  tasks D%d R%d ▶%d ✓%d  ·  output %s%s' \
      "$(tput el 2>/dev/null || true)" "$C_DIM" "$mm" "$ss" "$cur" \
      "$draft" "$ready" "$running" "$committed" "$alive" "$C_RST"
    sleep 3
  done
  printf '\r%s' "$(tput el 2>/dev/null || true)"
  wait "$wpid" 2>/dev/null || true
}

cmd_web() {
  command -v python3 >/dev/null 2>&1 || die "mux web needs python3"

  # --- branch selection (the front door to a session) --------------------
  # Parse the leading args: an optional `--new` forces the prompt; the first
  # positional is a BRANCH name unless it's purely numeric (back-compat: the
  # historical `mux web <port>` / `mux start <port>` still works).
  local force_new="" branch_arg=""
  if [ "${1:-}" = "--new" ]; then force_new=1; shift; fi
  if [ -n "${1:-}" ]; then
    case "$1" in *[!0-9]*) branch_arg="$1"; shift ;; esac
  fi
  if [ -n "$branch_arg" ]; then
    start_checkout "$branch_arg"                          # mux start <branch> [port]
  elif [ -t 0 ] && [ -t 1 ] && { [ -n "$force_new" ] || ! session_in_flight; }; then
    start_tui                                             # fresh start → interactive picker
  else
    local cur; cur="$(git branch --show-current 2>/dev/null || true)"
    [ -n "$cur" ] && echo "▶ continuing on $cur"          # in-flight → zero-friction resume
  fi
  # A dry-run hook (tests): stop after branch selection, before the UI/loop.
  [ -n "${MUX_START_DRYRUN:-}" ] && return 0

  local port="${1:-8770}"   # NOT 7000 — macOS AirPlay Receiver squats on 7000
  mkdir -p .mux/log .mux/run
  cmd_stop >/dev/null 2>&1                 # clean up any previous mux web for this repo
  cmd_output "${2:-10s}" >> .mux/log/output.loop 2>&1 &
  local epid=$!; echo "$epid" > .mux/run/output.pid
  MUX_REPO="$REPO_ROOT" MUX_BIN="$SELF_DIR/mux.sh" MUX_PORT="$port" python3 "$SELF_DIR/server.py" &
  local wpid=$!; echo "$wpid" > .mux/run/web.pid
  # Kill the loop + server first (so no fresh tick spawns), then halt any
  # in-flight tick (kill_tick drops tick.pid + the lock once its claude is gone),
  # then sweep the remaining pid files. kill_tick MUST run before the *.pid rm,
  # or the rm would delete tick.pid out from under it.
  # HUP is in the list so closing the terminal (which sends SIGHUP) tears the
  # whole tree down too — without it the script orphaned to PID 1 and its
  # output + in-flight claude kept running after the window was gone.
  trap 'kill "$epid" "$wpid" 2>/dev/null; kill_tick; rm -f "$REPO_ROOT"/.mux/run/*.pid' EXIT INT TERM HUP
  echo "▶ mux web → http://127.0.0.1:$port    (Ctrl-C or closing this window stops UI + output; or run: mux stop)"
  # Pop the browser once the server is listening, unless told not to (MUX_NO_OPEN=1).
  if [ -z "${MUX_NO_OPEN:-}" ]; then
    local opener=""; command -v open >/dev/null 2>&1 && opener=open || { command -v xdg-open >/dev/null 2>&1 && opener=xdg-open; }
    [ -n "$opener" ] && ( sleep 0.6; "$opener" "http://127.0.0.1:$port" ) >/dev/null 2>&1 &
  fi
  # On a TTY, keep showing periodic live status; otherwise block silently (so
  # logs/CI aren't spammed). Either way the EXIT/INT/TERM/HUP trap above owns
  # teardown — start_status_loop only blocks until $wpid dies, then reaps it.
  if [ -t 1 ]; then start_status_loop "$wpid"; else wait "$wpid"; fi
}

cmd_help() { sed -n '2,/^$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; }

# --- dispatch --------------------------------------------------------------

cmd="${1:-status}"; shift || true
case "$cmd" in
  add)            cmd_add "$@" ;;
  release)        cmd_release "$@" ;;
  unrelease)      cmd_unrelease "$@" ;;
  claim)          cmd_claim "$@" ;;
  start|web)      cmd_web "$@" ;;
  block)          cmd_block "$@" ;;
  resolve)        cmd_resolve "$@" ;;
  fail)           cmd_fail "$@" ;;
  revert)         cmd_revert "$@" ;;
  delete|rm)      cmd_delete "$@" ;;
  ok)             cmd_ok "$@" ;;
  end)            cmd_end "$@" ;;
  changes)        cmd_changes "$@" ;;
  show)           cmd_show "$@" ;;
  ls|status)      cmd_status "$@" ;;
  board)          cmd_board "$@" ;;
  next)           cmd_next "$@" ;;
  _list)          cmd_list "$@" ;;
  channel)        cmd_channel "$@" ;;
  output)       cmd_output "$@" ;;
  tick)           cmd_tick "$@" ;;
  stop)           cmd_stop "$@" ;;
  help|-h|--help) cmd_help ;;
  *)              die "unknown verb '$cmd' — try:  mux help" ;;
esac

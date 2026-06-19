#!/usr/bin/env bash
# test_mux.sh — dependency-free bash test suite for ../mux.sh (the "verb layer").
#
# Proves the state-machine rules (cmd_release/claim/block/resolve/ok/fail/revert)
# and the output's task-selection logic (cmd_next), plus resolve_id + status
# --json. No bats, no extra deps — just bash + git + awk/sed/grep + python3.
#
# Each test runs against a THROWAWAY git repo (mktemp -d), never the real one:
# mux.sh does `git rev-parse --show-toplevel` and cd's there, so we invoke it
# from inside a temp repo's CWD via a subshell. The real repo is never touched.
#
# Run:  bash mux/tests/test_mux.sh
# Exits 0 iff every assertion passes; non-zero otherwise.

# NOTE: deliberately NO `set -e` here — we capture non-zero exit codes from
# mux.sh as data (RC) to assert that illegal transitions are refused.

# --- locate the script under test, ONCE, before any cd --------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUX="$(cd "$TEST_DIR/.." && pwd)/mux.sh"
[ -f "$MUX" ] || { echo "cannot find mux.sh at $MUX" >&2; exit 2; }

# --- temp-repo bookkeeping + cleanup --------------------------------------
TMPDIRS=()
mktmp() { local d; d="$(mktemp -d)"; TMPDIRS+=("$d"); printf '%s\n' "$d"; }
cleanup() { local d; for d in "${TMPDIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# A fresh git repo with one commit so HEAD exists; prints its path.
setup_repo() {
  local d; d="$(mktmp)"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo init > README.md
    git add README.md
    git commit -qm init
  )
  printf '%s\n' "$d"
}

# Create a task file directly, in a chosen status (isolates the verb under test).
# mk_task <dir> <filename> <status> [extra_header_line]
mk_task() {
  local d="$1" name="$2" st="$3" extra="${4:-}"
  mkdir -p "$d/.mux/tasks"
  {
    echo "# Task: ${name%.task.md}"
    echo "# STATUS: $st"
    [ -n "$extra" ] && echo "$extra"
    echo "## Goal"
    echo "goal text"
    echo "## Details"
    echo "-"
  } > "$d/.mux/tasks/$name"
}

# Read a task file's STATUS (same logic as mux.sh task_status).
status_of() { grep -m1 -i '^# STATUS:' "$1" | sed 's/.*STATUS:[[:space:]]*//' | awk '{print $1}'; }

# Rewrite a STATUS line in place (for setting up dependency-done fixtures).
flip_status() {
  local f="$1" s="$2" t; t="$(mktemp)"
  awk -v s="$s" '/^# STATUS:/&&!d{print "# STATUS: " s; d=1; next}{print}' "$f" > "$t"
  mv "$t" "$f"
}

# Invoke mux.sh inside a temp repo; capture combined output in OUT and code in RC.
# m <dir> <verb> [args...]
m() {
  local d="$1"; shift
  OUT="$( cd "$d" && bash "$MUX" "$@" 2>&1 )"; RC=$?
}

# --- assertions -----------------------------------------------------------
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '    \033[32mPASS\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '    \033[31mFAIL\033[0m %s\n' "$1"; }

# assert <desc> <test-expr...>  — evaluates the expression; pass if it succeeds.
assert() { local desc="$1"; shift; if "$@"; then ok "$desc"; else no "$desc"; fi; }
assert_eq() { # <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got [$2], want [$3])"; fi; }
assert_zero() { if [ "$RC" -eq 0 ]; then ok "$1"; else no "$1 (rc=$RC: $OUT)"; fi; }
assert_nonzero() { if [ "$RC" -ne 0 ]; then ok "$1"; else no "$1 (rc=0, unexpectedly succeeded)"; fi; }
assert_contains() { # <desc> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1";; *) no "$1 (missing [$3] in: $2)";; esac; }
assert_file_contains() { if grep -q "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1 (no [$2] in $3)"; fi; }
assert_status() { assert_eq "$1" "$(status_of "$3")" "$2"; }  # <desc> <want> <file>

header() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }

# ==========================================================================
# 1. add creates a DRAFT task with slug, STATUS line, and goal text.
# ==========================================================================
test_add() {
  header "add creates a DRAFT task"
  local d; d="$(setup_repo)"
  m "$d" add myslug "ship the widget"
  assert_zero "add exits 0"
  local f; f="$(ls "$d"/.mux/tasks/*myslug*.task.md 2>/dev/null)"
  assert "task file was created" test -f "$f"
  assert_file_contains "STATUS is DRAFT" '^# STATUS: DRAFT' "$f"
  assert_file_contains "contains the slug" 'myslug' "$f"
  assert_file_contains "contains the goal text" 'ship the widget' "$f"
}

# task_channel parses the `# Channel:` planner-session header that channels
# stamp onto every task (used by the web `direct ⇥` resume). Eval just the
# one-line parser out of mux.sh so we exercise the real definition without
# running the dispatch at the bottom of the script.
test_task_channel() {
  header "task_channel parses the # Channel: header"
  eval "$(grep -m1 '^task_channel()' "$MUX")"
  local d; d="$(setup_repo)"
  local sid="0123abcd-4567-89ab-cdef-0123456789ab"
  mk_task "$d" "ch.task.md" DRAFT "# Channel: $sid"
  assert_eq "reads the channel session id" "$(task_channel "$d/.mux/tasks/ch.task.md")" "$sid"
  mk_task "$d" "noch.task.md" DRAFT
  assert_eq "empty when no # Channel: header" "$(task_channel "$d/.mux/tasks/noch.task.md")" ""
}

# ==========================================================================
# 2. Happy path: add -> release (DRAFT->READY) -> claim (READY->RUNNING).
# ==========================================================================
test_happy_path() {
  header "happy path add -> release -> claim"
  local d; d="$(setup_repo)"
  m "$d" add happy "do the thing"
  local f; f="$(ls "$d"/.mux/tasks/*happy*.task.md)"
  assert_status "after add: DRAFT" DRAFT "$f"
  m "$d" release happy
  assert_zero "release exits 0"
  assert_status "after release: READY" READY "$f"
  m "$d" claim happy
  assert_zero "claim exits 0 (only .mux is dirty)"
  assert_status "after claim: RUNNING" RUNNING "$f"
}

# ==========================================================================
# 2a. unrelease is the inverse of release: READY -> DRAFT, and only READY.
# ==========================================================================
test_unrelease() {
  header "unrelease READY -> DRAFT (regret a release)"
  local d; d="$(setup_repo)"
  m "$d" add reg "do the thing"
  local f; f="$(ls "$d"/.mux/tasks/*reg*.task.md)"
  m "$d" release reg
  assert_status "after release: READY" READY "$f"
  m "$d" unrelease reg
  assert_zero "unrelease exits 0"
  assert_status "after unrelease: DRAFT" DRAFT "$f"
  # Guarded to READY: unrelease on a DRAFT is refused.
  m "$d" unrelease reg
  assert_nonzero "unrelease on a non-READY task is refused"
}

# ==========================================================================
# 2b. Auto mode (the .mux/auto flag) makes the executor run DRAFTs IN PLACE:
#     `next` selects a DRAFT and `claim` flips it DRAFT->RUNNING, all WITHOUT a
#     DRAFT->READY rewrite — so toggling auto off leaves un-run tasks DRAFT.
# ==========================================================================
test_auto_runs_drafts() {
  header "auto mode: next/claim run DRAFTs in place (no DRAFT->READY rewrite)"
  local d; d="$(setup_repo)"
  local f="$d/.mux/tasks/20200101-000000-drf.task.md"
  mk_task "$d" "20200101-000000-drf.task.md" DRAFT

  # Auto OFF: a DRAFT is not runnable.
  m "$d" next
  assert_eq "next ignores a DRAFT while auto is off" "$OUT" ""
  m "$d" claim drf
  assert_nonzero "claim refuses a DRAFT while auto is off"
  assert_status "DRAFT untouched after refused claim" DRAFT "$f"

  # Auto ON: the executor runs the DRAFT in place.
  touch "$d/.mux/auto"
  m "$d" next
  assert_eq "next selects the DRAFT while auto is on" "$OUT" "20200101-000000-drf.task.md"
  assert_status "next does NOT rewrite the DRAFT's status" DRAFT "$f"
  m "$d" claim drf
  assert_zero "claim accepts a DRAFT while auto is on"
  assert_status "claim flips DRAFT straight to RUNNING" RUNNING "$f"
}

# ==========================================================================
# 3. Illegal transitions are refused with non-zero exit.
# ==========================================================================
test_illegal_transitions() {
  header "illegal transitions are refused"
  local d; d="$(setup_repo)"

  mk_task "$d" "20200101-000000-rel.task.md" READY
  m "$d" release rel
  assert_nonzero "release on a non-DRAFT task is refused"

  mk_task "$d" "20200101-000000-clm.task.md" DRAFT
  m "$d" claim clm
  assert_nonzero "claim on a non-READY task is refused"

  local e; e="$(setup_repo)"
  m "$e" ok
  assert_nonzero "ok with no RUNNING task is refused"
  m "$e" revert
  assert_nonzero "revert with no RUNNING task is refused"

  mk_task "$d" "20200101-000000-res.task.md" READY
  m "$d" resolve res "an answer"
  assert_nonzero "resolve on a non-BLOCKED task is refused"
}

# ==========================================================================
# 4. claim refuses a dirty non-.mux tree, succeeds when only .mux is dirty.
# ==========================================================================
test_claim_clean_check() {
  header "claim honors git_clean (ignores .mux)"
  local d; d="$(setup_repo)"
  mk_task "$d" "20200101-000000-dirty.task.md" READY
  echo "stray" > "$d/src.txt"          # untracked non-.mux change
  m "$d" claim dirty
  assert_nonzero "claim refuses a dirty working tree (non-.mux change present)"
  assert_status "task stays READY after refused claim" READY "$d/.mux/tasks/20200101-000000-dirty.task.md"
  rm -f "$d/src.txt"                    # now only .mux is dirty
  m "$d" claim dirty
  assert_zero "claim succeeds when only .mux paths are dirty"
  assert_status "task is RUNNING after successful claim" RUNNING "$d/.mux/tasks/20200101-000000-dirty.task.md"
}

# ==========================================================================
# 5. block appends ## Question; resolve appends ## Answer (when answer given).
# ==========================================================================
test_block_resolve() {
  header "block appends Question, resolve appends Answer"
  local d; d="$(setup_repo)"
  local f="$d/.mux/tasks/20200101-000000-bq.task.md"
  mk_task "$d" "20200101-000000-bq.task.md" RUNNING
  m "$d" block bq "which database should I use?"
  assert_zero "block exits 0"
  assert_status "block: RUNNING -> BLOCKED" BLOCKED "$f"
  assert_file_contains "block appended a ## Question block" '^## Question' "$f"
  assert_file_contains "question text is recorded" 'which database' "$f"
  m "$d" resolve bq "use sqlite"
  assert_zero "resolve exits 0"
  assert_status "resolve: BLOCKED -> READY" READY "$f"
  assert_file_contains "resolve appended a ## Answer block" '^## Answer' "$f"
  assert_file_contains "answer text is recorded" 'use sqlite' "$f"
}

# ==========================================================================
# 6. ok commits exactly one commit on the current branch, transitions the task
#    to COMMITTED IN PLACE (recording the SHA + branch on the file), excludes
#    .mux from the commit. ok with no changes refused.
# ==========================================================================
test_ok_commit() {
  header "ok commits one commit (excluding .mux) and marks the task COMMITTED"
  local d; d="$(setup_repo)"
  local f="$d/.mux/tasks/20200101-000000-okc.task.md"
  mk_task "$d" "20200101-000000-okc.task.md" RUNNING
  echo "feature code" > "$d/app.txt"             # real (non-.mux) file change

  local before after files sha
  before="$(cd "$d" && git rev-list --count HEAD)"
  m "$d" ok "looks good"
  assert_zero "ok exits 0 when there are real file changes"
  after="$(cd "$d" && git rev-list --count HEAD)"
  assert_eq "exactly one new commit was created" "$after" "$((before+1))"
  assert "task file stays after ok" test -e "$f"
  assert_status "ok marks the task COMMITTED" COMMITTED "$f"
  assert_contains "ok reports it is awaiting push" "$OUT" "awaiting push"
  sha="$(cd "$d" && git rev-parse --short HEAD)"
  assert_file_contains "the short SHA is recorded on the task" "^# Commit: $sha" "$f"
  assert_file_contains "the branch is recorded on the task" "^# Branch: " "$f"

  files="$(cd "$d" && git show --name-only --pretty=format: HEAD)"
  assert_contains "the commit includes the real file" "$files" "app.txt"
  if printf '%s\n' "$files" | grep -q '\.mux'; then
    no ".mux was excluded from the commit"
  else
    ok ".mux was excluded from the commit"
  fi

  # ok with no file changes (only .mux dirty) must be refused.
  local e; e="$(setup_repo)"
  mk_task "$e" "20200101-000000-noc.task.md" RUNNING
  m "$e" ok
  assert_nonzero "ok with no real file changes is refused"
  assert_contains "refusal mentions no file changes" "$OUT" "no file changes"
}

# ==========================================================================
# 6b. ok writes the full Goal block into the commit body (more than one line),
#     and the approved task still appears on the board as COMMITTED carrying its
#     short SHA (status --json).
# ==========================================================================
test_ok_commit_summary_and_board() {
  header "ok puts the whole Goal in the commit body and keeps the task as COMMITTED"
  command -v python3 >/dev/null 2>&1 || { no "python3 not available to validate JSON"; return; }
  local d; d="$(setup_repo)"
  local f="$d/.mux/tasks/20200101-000000-sum.task.md"
  mkdir -p "$d/.mux/tasks"
  {
    echo "# Task: sum"
    echo "# STATUS: RUNNING"
    echo "## Goal"
    echo "first goal line is the subject"
    echo "second goal line in the body"
    echo "third goal line in the body"
    echo "## Details"
    echo "details should NOT appear in the commit"
  } > "$f"
  echo "feature code" > "$d/app.txt"

  m "$d" ok
  assert_zero "ok exits 0"
  local body; body="$(cd "$d" && git log -1 --pretty=%B)"
  assert_contains "subject carries the slug + first Goal line" "$body" "sum: first goal line is the subject"
  assert_contains "body carries the second Goal line"          "$body" "second goal line in the body"
  assert_contains "body carries the third Goal line"           "$body" "third goal line in the body"
  assert_contains "body names the task file"                   "$body" "task: 20200101-000000-sum.task.md"
  case "$body" in *"details should NOT appear"*) no "Details leaked into the commit body";; *) ok "Details excluded from the commit body";; esac

  m "$d" status --json
  assert_zero "status --json exits 0 after the task is approved"
  case "$OUT" in *"20200101-000000-sum.task.md"*) ok "committed task still listed on the board";; *) no "committed task missing from the board";; esac
  assert_contains "the board reports it COMMITTED" "$OUT" '"status":"COMMITTED"'
  case "$OUT" in *'"commit":"'*) ok "the JSON carries a commit SHA";; *) no "the JSON is missing the commit SHA";; esac
}

# ==========================================================================
# 6c. A READY task that Depends-on an already-approved (now COMMITTED) task is
#     still pickable: status --json reports its dep done and mux next chooses it.
# ==========================================================================
test_depends_on_deleted_dep() {
  header "a dep that was approved (COMMITTED) still satisfies a dependent"
  command -v python3 >/dev/null 2>&1 || { no "python3 not available to validate JSON"; return; }
  local d; d="$(setup_repo)"
  local dep="20200101-000000-depdel.task.md"
  # Approve the dependency so it becomes COMMITTED and is recorded in done.log.
  mk_task "$d" "$dep" RUNNING
  echo "dep code" > "$d/dep.txt"
  m "$d" ok
  assert_zero "approving the dependency exits 0"
  assert_status "dependency is now COMMITTED" COMMITTED "$d/.mux/tasks/$dep"
  assert_file_contains "done.log records the committed dependency" "$dep" "$d/.mux/done.log"

  # A dependent task pointing at the now-COMMITTED dep must read as satisfied.
  mk_task "$d" "20200102-000000-depdent.task.md" READY "# Depends-on: $dep"
  m "$d" status --json
  assert_zero "status --json exits 0"
  assert_contains "dependent's dep_status is done (not pending)" "$OUT" '"dep_status":"done"'
  case "$OUT" in *'"dep_status":"pending"'*) no "dep still reads pending after deletion";; *) ok "no pending dep_status remains";; esac

  m "$d" next
  assert_eq "next chooses the dependent now its dep is satisfied" "$OUT" "20200102-000000-depdent.task.md"
}

# ==========================================================================
# 7. revert/fail on a RUNNING task discard working-tree changes -> FAILED.
# ==========================================================================
test_revert_fail_discard() {
  header "revert/fail discard changes and mark FAILED"
  local d; d="$(setup_repo)"
  local f="$d/.mux/tasks/20200101-000000-flr.task.md"
  mk_task "$d" "20200101-000000-flr.task.md" RUNNING
  echo "wip" > "$d/wip.txt"
  m "$d" fail flr "premise was wrong"
  assert_zero "fail exits 0"
  assert_status "fail: RUNNING -> FAILED" FAILED "$f"
  assert "fail discarded the created source file" test ! -e "$d/wip.txt"
  assert_file_contains "fail recorded a reason" 'premise was wrong' "$f"

  local e; e="$(setup_repo)"
  local g="$e/.mux/tasks/20200101-000000-rvt.task.md"
  mk_task "$e" "20200101-000000-rvt.task.md" RUNNING
  echo "wip2" > "$e/wip2.txt"
  m "$e" revert
  assert_zero "revert exits 0"
  assert_status "revert: RUNNING -> FAILED" FAILED "$g"
  assert "revert discarded the created source file" test ! -e "$e/wip2.txt"
}

# ==========================================================================
# 7b. delete removes a FAILED task file; refuses any other state.
# ==========================================================================
test_delete() {
  header "delete clears a FAILED or DRAFT task, refuses others"
  local d; d="$(setup_repo)"
  local f="$d/.mux/tasks/20200101-000000-del.task.md"
  mk_task "$d" "20200101-000000-del.task.md" FAILED
  m "$d" delete del
  assert_zero "delete exits 0 on a FAILED task"
  assert "delete removed the FAILED task file" test ! -e "$f"

  # A DRAFT never ran, so it's deletable too.
  local h="$d/.mux/tasks/20200101-000000-drf.task.md"
  mk_task "$d" "20200101-000000-drf.task.md" DRAFT
  m "$d" delete drf
  assert_zero "delete exits 0 on a DRAFT task"
  assert "delete removed the DRAFT task file" test ! -e "$h"

  local g="$d/.mux/tasks/20200101-000000-rdy.task.md"
  mk_task "$d" "20200101-000000-rdy.task.md" READY
  m "$d" delete rdy
  assert_nonzero "delete refuses a READY (non-DRAFT/FAILED) task"
  assert "delete left the READY file in place" test -e "$g"
}

# ==========================================================================
# 8. cmd_next selection logic.
# ==========================================================================
test_next_dirty() {
  header "next prints nothing when the tree is dirty"
  local d; d="$(setup_repo)"
  mk_task "$d" "20200101-000000-rdy.task.md" READY
  echo "uncommitted" > "$d/pending.txt"     # work awaiting `mux ok`
  m "$d" next
  assert_zero "next exits 0 even when dirty"
  assert_eq "next prints nothing while tree is dirty" "$OUT" ""
}

test_next_running_wins() {
  header "next: a RUNNING task wins over READY"
  local d; d="$(setup_repo)"
  mk_task "$d" "20200101-000000-aaa-ready.task.md" READY     # earlier filename
  mk_task "$d" "20200102-000000-bbb-running.task.md" RUNNING # later, but RUNNING
  m "$d" next
  assert_eq "next selects the RUNNING task" "$OUT" "20200102-000000-bbb-running.task.md"
}

test_next_fifo() {
  header "next: FIFO-oldest READY task is chosen"
  local d; d="$(setup_repo)"
  mk_task "$d" "20200102-000000-second.task.md" READY
  mk_task "$d" "20200101-000000-first.task.md" READY        # earlier -> should win
  m "$d" next
  assert_eq "next selects the oldest READY by filename" "$OUT" "20200101-000000-first.task.md"
}

test_next_depends_on() {
  header "next: a READY task is gated by # Depends-on: until the dep is DONE"
  local d; d="$(setup_repo)"
  local dep="20200101-000000-dep-a.task.md"
  mk_task "$d" "$dep" DRAFT                                   # dependency, NOT done
  mk_task "$d" "20200102-000000-dep-b.task.md" READY "# Depends-on: $dep"
  m "$d" next
  assert_eq "dependent task is skipped while dep is not DONE" "$OUT" ""
  flip_status "$d/.mux/tasks/$dep" DONE
  m "$d" next
  assert_eq "dependent task becomes selectable once dep is DONE" "$OUT" "20200102-000000-dep-b.task.md"
}

# ==========================================================================
# 9. status --json emits valid JSON with the expected fields.
# ==========================================================================
test_status_json() {
  header "status --json emits valid JSON with expected fields"
  command -v python3 >/dev/null 2>&1 || { no "python3 not available to validate JSON"; return; }
  local d; d="$(setup_repo)"
  local dep="20200101-000000-jdep.task.md"
  mk_task "$d" "$dep" DONE
  mk_task "$d" "20200102-000000-jrun.task.md" RUNNING
  mk_task "$d" "20200103-000000-jrdy.task.md" READY "# Depends-on: $dep"
  m "$d" status --json
  assert_zero "status --json exits 0"
  if printf '%s' "$OUT" | python3 -m json.tool >/dev/null 2>&1; then
    ok "status --json output is valid JSON"
  else
    no "status --json output is valid JSON (got: $OUT)"
  fi
  assert_contains "JSON has a status field"     "$OUT" '"status"'
  assert_contains "JSON has a current field"    "$OUT" '"current"'
  assert_contains "JSON has a next field"       "$OUT" '"next"'
  assert_contains "JSON has a depends_on field" "$OUT" '"depends_on"'
}

# ==========================================================================
# 10. resolve_id: unique substring resolves; ambiguous substring errors.
# ==========================================================================
test_resolve_id() {
  header "resolve_id resolves a unique substring, errors on an ambiguous one"
  local d; d="$(setup_repo)"
  mk_task "$d" "20200101-000000-lonelyxyz.task.md" DRAFT
  mk_task "$d" "20200102-000000-dupone.task.md" DRAFT
  mk_task "$d" "20200103-000000-duptwo.task.md" DRAFT
  m "$d" show lonelyxyz
  assert_zero "show resolves a unique substring"
  m "$d" show dup
  assert_nonzero "show errors on an ambiguous substring"
  assert_contains "ambiguity is reported" "$OUT" "ambiguous"
}

# ==========================================================================
# 11. stop kills an in-flight tick (the backgrounded `claude` child) and only
#     then clears .mux/tick.lock + .mux/run/tick.pid. Uses a stub `claude` on
#     PATH so no real model run is needed.
# ==========================================================================
test_stop_kills_tick() {
  header "stop kills the in-flight tick, clearing the lock only after"
  command -v ps >/dev/null 2>&1 || { no "ps not available to test tick teardown"; return; }
  local d; d="$(setup_repo)"
  # Stub `claude` (named so its command line matches kill_tick's `claude` check);
  # it stays alive in short sleeps so a kill lands within ~0.1s, no orphan.
  local bin="$d/bin"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
i=0; while [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done
STUB
  chmod +x "$bin/claude"

  # Run ONE tick in the background; it blocks in the stub claude, holding the lock.
  ( cd "$d" && PATH="$bin:$PATH" bash "$MUX" tick ) >/dev/null 2>&1 &
  local tickrun=$!

  # Wait for the tick to record its claude pid and take the lock.
  local pid="" i=0
  while [ "$i" -lt 50 ]; do
    if [ -s "$d/.mux/run/tick.pid" ]; then pid="$(cat "$d/.mux/run/tick.pid")"; [ -n "$pid" ] && break; fi
    sleep 0.1; i=$((i+1))
  done
  assert "tick recorded its claude pid" test -n "$pid"
  assert "tick.lock is held while the tick runs" test -d "$d/.mux/tick.lock"
  assert "the stubbed claude is alive while the tick runs" sh -c "ps -p $pid >/dev/null 2>&1"

  # Stop it: the loop isn't running here, so this exercises kill_tick directly.
  ( cd "$d" && PATH="$bin:$PATH" bash "$MUX" stop ) >/dev/null 2>&1

  # The claude child must be gone, and only THEN the lock + pid cleared.
  i=0; while [ "$i" -lt 50 ] && ps -p "$pid" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
  assert_eq "stop killed the in-flight claude" "$(ps -p "$pid" -o pid= 2>/dev/null | tr -d ' ')" ""
  assert "tick.lock removed after the kill" test ! -d "$d/.mux/tick.lock"
  assert "tick.pid removed after the kill" test ! -f "$d/.mux/run/tick.pid"

  wait "$tickrun" 2>/dev/null
}

# ==========================================================================
# 12. A tick killed mid-cycle flags its RUNNING task as interrupted, so it
#     can't be mistaken for finished work awaiting `mux ok`. The marker is
#     appended during teardown (kill_tick), kept while STATUS stays RUNNING,
#     and `status --json` reports interrupted:true while the tree is dirty.
# ==========================================================================
test_interrupted_marker() {
  header "a killed tick flags its RUNNING task interrupted"
  command -v ps >/dev/null 2>&1 || { no "ps not available to test interrupted teardown"; return; }
  command -v python3 >/dev/null 2>&1 || { no "python3 not available to validate JSON"; return; }
  local d; d="$(setup_repo)"
  local f="$d/.mux/tasks/20200101-000000-irq.task.md"
  mk_task "$d" "20200101-000000-irq.task.md" RUNNING
  echo "half-finished edit" > "$d/partial.txt"   # PARTIAL work in the tree

  # Stub claude that blocks so the tick holds the lock until we stop it.
  local bin="$d/bin"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
i=0; while [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done
STUB
  chmod +x "$bin/claude"

  ( cd "$d" && PATH="$bin:$PATH" bash "$MUX" tick ) >/dev/null 2>&1 &
  local tickrun=$!
  local pid="" i=0
  while [ "$i" -lt 50 ]; do
    if [ -s "$d/.mux/run/tick.pid" ]; then pid="$(cat "$d/.mux/run/tick.pid")"; [ -n "$pid" ] && break; fi
    sleep 0.1; i=$((i+1))
  done
  assert "tick recorded its claude pid" test -n "$pid"

  # Stop mid-tick: kill_tick marks the RUNNING task interrupted as it tears down.
  ( cd "$d" && PATH="$bin:$PATH" bash "$MUX" stop ) >/dev/null 2>&1
  i=0; while [ "$i" -lt 50 ] && ps -p "$pid" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done

  assert_status "interrupted task stays RUNNING (marker is an annotation)" RUNNING "$f"
  assert_file_contains "an # Interrupted: line was appended" '^# Interrupted:' "$f"

  m "$d" status
  assert_contains "status flags it interrupted" "$OUT" "interrupted — revert & re-release"

  m "$d" status --json
  assert_zero "status --json exits 0"
  assert_contains "JSON has an interrupted field" "$OUT" '"interrupted"'
  assert_contains "JSON reports interrupted:true while the tree is dirty" "$OUT" '"interrupted":true'

  wait "$tickrun" 2>/dev/null
}

# ==========================================================================
header "mux web / bare mux — branch selection (the session front door)"
# ==========================================================================
# MUX_START_DRYRUN=1 makes cmd_web do ONLY branch selection then return, so we
# can assert the create-or-checkout effects without launching the loop/server.
# Stdin is not a tty under the test harness, so the fresh-start picker is auto-
# skipped (continues silently) — these tests cover the non-interactive paths.
# `mux web` is the explicit form; bare `mux` is the same command (default verb).
test_start_branch() {
  local d; d="$(setup_repo)"
  local base; base="$( cd "$d" && git branch --show-current )"

  # mux web <newbranch> → creates it, switches, records the base.
  OUT="$( cd "$d" && MUX_START_DRYRUN=1 MUX_NO_OPEN=1 bash "$MUX" web newfeat 2>&1 )"; RC=$?
  assert_zero "start <newbranch> exits 0"
  assert_contains "start <newbranch> reports creation" "$OUT" "created branch newfeat"
  assert_eq "switched to the new branch" "$( cd "$d" && git branch --show-current )" "newfeat"
  assert_file_contains "records the forked-from base" "$base" "$d/.mux/base"

  # On the feature branch with an unpushed commit, a no-arg start CONTINUES.
  ( cd "$d" && echo x > f.txt && git add f.txt && git commit -qm work )
  OUT="$( cd "$d" && MUX_START_DRYRUN=1 MUX_NO_OPEN=1 bash "$MUX" web 2>&1 )"; RC=$?
  assert_contains "in-flight (unpushed) start continues silently" "$OUT" "continuing on newfeat"
  assert_eq "stayed on the feature branch" "$( cd "$d" && git branch --show-current )" "newfeat"

  # A numeric first arg is still the PORT, never a branch name.
  OUT="$( cd "$d" && MUX_START_DRYRUN=1 MUX_NO_OPEN=1 bash "$MUX" web 9999 2>&1 )"; RC=$?
  assert_zero "start <port> (numeric) exits 0"
  assert_eq "numeric arg did not create a branch" "$( cd "$d" && git branch --show-current )" "newfeat"

  # mux start <existing> checks it out (back to base).
  OUT="$( cd "$d" && MUX_START_DRYRUN=1 MUX_NO_OPEN=1 bash "$MUX" web "$base" 2>&1 )"; RC=$?
  assert_zero "start <existing> exits 0"
  assert_eq "checked out the existing branch" "$( cd "$d" && git branch --show-current )" "$base"

  # An invalid branch name is rejected.
  OUT="$( cd "$d" && MUX_START_DRYRUN=1 MUX_NO_OPEN=1 bash "$MUX" web 'bad..name' 2>&1 )"; RC=$?
  assert_nonzero "web rejects an invalid branch name"

  # Bare `mux` (NO args) is the SAME command as `mux web` — the default verb.
  # (A branch is given via `mux web <branch>`; bare `mux` just resumes/continues.)
  ( cd "$d" && git checkout -q "$base" )
  OUT="$( cd "$d" && MUX_START_DRYRUN=1 MUX_NO_OPEN=1 bash "$MUX" 2>&1 )"; RC=$?
  assert_zero "bare mux (no args) exits 0 (default verb = web)"
  assert_contains "bare mux runs the session front door" "$OUT" "continuing on $base"

  # The old `start` verb is gone — it must error, not silently launch anything.
  OUT="$( cd "$d" && MUX_START_DRYRUN=1 MUX_NO_OPEN=1 bash "$MUX" start 2>&1 )"; RC=$?
  assert_nonzero "removed 'start' verb is rejected"
  assert_contains "start reports unknown verb" "$OUT" "unknown verb"
}

# ==========================================================================
# cmd_end (Ship): a SUCCESSFUL push wipes ALL local mux state under .mux/ so the
# next session on this checkout starts clean; a FAILED push leaves it intact.
# Push is exercised against a real bare remote (no stub needed) so it succeeds
# offline; the failure path points origin at a non-existent path so push dies.
# ==========================================================================
test_end_wipes_state() {
  header "end wipes local mux state on a successful push"
  local d; d="$(setup_repo)"
  # A bare remote + upstream so `git push` succeeds with no network.
  local rem; rem="$(mktmp)"
  ( cd "$rem" && git init -q --bare )
  ( cd "$d" && git remote add origin "$rem" && git push -q -u origin HEAD )
  # base = the current branch so end won't try to checkout away.
  local cur; cur="$( cd "$d" && git branch --show-current )"
  mkdir -p "$d/.mux/log" "$d/.mux/run"
  echo '{}'  > "$d/.mux/log/output.jsonl"
  echo note  > "$d/.mux/NOTES.md"
  printf 'x\ty\tz\n' > "$d/.mux/done.log"
  echo "$cur" > "$d/.mux/base"
  mk_task "$d" "leftover-draft.task.md" DRAFT

  m "$d" end
  assert_zero "end exits 0 on a successful push"
  assert_contains "end reports the wipe" "$OUT" "wiped local mux state"
  assert "log transcripts are gone"    sh -c "! test -e '$d/.mux/log'"
  assert "NOTES.md is gone"            sh -c "! test -e '$d/.mux/NOTES.md'"
  assert "leftover DRAFT task is gone" sh -c "! test -e '$d/.mux/tasks/leftover-draft.task.md'"
  assert "done.log is gone"            sh -c "! test -e '$d/.mux/done.log'"
  assert "base marker is gone"         sh -c "! test -e '$d/.mux/base'"
}

test_end_push_fail_keeps_state() {
  header "end leaves mux state intact when the push fails"
  local d; d="$(setup_repo)"
  # origin points at a path that does not exist + no upstream → push -u fails.
  ( cd "$d" && git remote add origin "$d/no-such-remote.git" )
  mkdir -p "$d/.mux/log"
  echo note > "$d/.mux/NOTES.md"

  m "$d" end
  assert_nonzero "end fails when the push fails"
  assert "mux state survives a failed push" test -d "$d/.mux"
  assert "NOTES.md survives a failed push"  test -f "$d/.mux/NOTES.md"
}

# --- run -------------------------------------------------------------------
test_add
test_task_channel
test_happy_path
test_unrelease
test_auto_runs_drafts
test_illegal_transitions
test_claim_clean_check
test_block_resolve
test_ok_commit
test_ok_commit_summary_and_board
test_depends_on_deleted_dep
test_revert_fail_discard
test_delete
test_next_dirty
test_next_running_wins
test_next_fifo
test_next_depends_on
test_status_json
test_resolve_id
test_stop_kills_tick
test_interrupted_marker
test_start_branch
test_end_wipes_state
test_end_push_fail_keeps_state

printf '\n\033[1m──────────────────────────────────────────\033[0m\n'
printf '\033[1mTotal: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "All tests passed."
exit 0

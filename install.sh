#!/usr/bin/env bash
# install.sh — drop claude-mux into a target repo, fully HIDDEN.
#
# Everything lands in ONE folder, .claude/mux/, so your repo root stays clean.
# The installer also registers it in the target repo's .git/info/exclude — a
# per-repo file that is NEVER committed — so git won't track, show
# (`git status`), or commit any of it, and collaborators never see it.
#
# Usage:  ./install.sh /path/to/your/repo

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:?usage: ./install.sh /path/to/your/repo}"
DEST="$(cd "$DEST" && pwd)"

[ -d "$DEST/.git" ] || { echo "✗ $DEST is not a git repo (no .git/ found)"; exit 1; }

# 1. Copy the whole payload into one folder.
mkdir -p "$DEST/.claude/mux"
cp "$SRC/mux/"*.sh "$DEST/.claude/mux/"
cp -R "$SRC/mux/prompts" "$DEST/.claude/mux/"
chmod +x "$DEST/.claude/mux/"*.sh

# 2. Hide from git via the per-repo, never-committed exclude file.
EXCLUDE="$DEST/.git/info/exclude"
mkdir -p "$DEST/.git/info"
add() { grep -qxF "$1" "$EXCLUDE" 2>/dev/null || echo "$1" >> "$EXCLUDE"; }
add "# claude-mux (local-only workflow, never committed)"
add "/.claude/mux/"
add "/.mux/"

echo "✓ installed into $DEST/.claude/mux/"
echo "  hidden via $EXCLUDE (not tracked, not committed, not visible to others)"
echo "  start with:  cd $DEST && .claude/mux/executor.sh"

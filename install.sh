#!/usr/bin/env bash
# install.sh — link the `mux` command onto your PATH, ONCE.
#
# claude-mux is centralized: a single checkout, symlinked onto your PATH, works
# in every git repo. `mux` finds the current repo and its .mux/ queue itself
# (via `git rev-parse`), so nothing is copied per-repo. Update everything later
# with one `git pull` in this checkout.
#
# Usage:  ./install.sh [bin-dir]        # bin-dir defaults to ~/.local/bin

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mux/mux.sh"
[ -f "$SRC" ] || { echo "✗ can't find $SRC"; exit 1; }
ROOT="$(cd "$(dirname "$SRC")/.." && pwd)"

BIN="${1:-$HOME/.local/bin}"
mkdir -p "$BIN"
LINK="$BIN/mux"

if [ -L "$LINK" ]; then
  ln -sf "$SRC" "$LINK"; echo "✓ relinked: $LINK -> $SRC"
elif [ -e "$LINK" ]; then
  echo "✗ $LINK exists and is not a symlink — move it aside, then re-run"; exit 1
else
  ln -s "$SRC" "$LINK"; echo "✓ linked:   $LINK -> $SRC"
fi

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "⚠ $BIN is not on your PATH — add it:"
     echo "    echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
esac

cat <<EOF

next:
  • from any git repo:        mux status  ·  mux planner  ·  mux executor
  • update every repo at once: git pull        (in $ROOT)
  • keep your queue out of git (your call — manual), e.g. globally:
        echo '.mux/' >> ~/.config/git/ignore
EOF

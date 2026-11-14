#!/usr/bin/env bash
# Install lanes: the skill into ~/.claude/skills/lanes and the CLI into
# ~/.local/bin/lanes, both as symlinks so `git pull` here updates them.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills/lanes"
mkdir -p "$HOME/.claude/skills" "$HOME/.local/bin"
ln -sfn "$SRC" "$HOME/.claude/skills/lanes"
ln -sfn "$SRC/bin/lanes" "$HOME/.local/bin/lanes"
chmod +x "$SRC/bin/lanes"
echo "lanes installed:"
echo "  skill: ~/.claude/skills/lanes -> $SRC"
echo "  CLI:   ~/.local/bin/lanes"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "  add ~/.local/bin to your PATH";; esac
echo "Next: cd into a repo and run 'lanes doctor', or ask Claude to 'set up lanes in this repo'."

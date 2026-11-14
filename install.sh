#!/usr/bin/env bash
# Install lanes without the plugin system: the skill into ~/.claude/skills/lanes
# and the CLI into ~/.local/bin/lanes, both as symlinks so `git pull` here
# updates them. Plugin users run this too if they want `lanes` in their own
# terminal or in git aliases (the plugin puts it on Claude's PATH only).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.claude/skills" "$HOME/.local/bin"
[ "${1:-}" = "--cli-only" ] || ln -sfn "$ROOT/skills/lanes" "$HOME/.claude/skills/lanes"
ln -sfn "$ROOT/bin/lanes" "$HOME/.local/bin/lanes"
chmod +x "$ROOT/bin/lanes"
echo "lanes installed:"
[ "${1:-}" = "--cli-only" ] || echo "  skill: ~/.claude/skills/lanes -> $ROOT/skills/lanes"
echo "  CLI:   ~/.local/bin/lanes -> $ROOT/bin/lanes"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "  add ~/.local/bin to your PATH";; esac
echo "Next: cd into a repo and run 'lanes doctor', or ask Claude to 'set up lanes in this repo'."

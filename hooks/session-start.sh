#!/usr/bin/env bash
# Plugin SessionStart hook. A plugin hook runs in every repo, so stay silent
# unless this repo uses lanes (.lanes.conf), and skip when the repo still has
# its own `lanes status` hook from templates/settings.json (no double briefing).
top="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f "$top/.lanes.conf" ] || exit 0
grep -qs 'lanes status' "$top/.claude/settings.json" && exit 0
"$(dirname "${BASH_SOURCE[0]}")/../bin/lanes" status 2>/dev/null || true

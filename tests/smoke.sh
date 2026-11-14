#!/usr/bin/env bash
# Smoke tests for lanes. Offline and harmless: a local bare repo as origin and
# a fake `docker` that only logs what it would do.
#   tests/smoke.sh                 # test bin/lanes
#   LANES_BIN=/path/to/lanes tests/smoke.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANES="${LANES_BIN:-$HERE/bin/lanes}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { echo "  ok    $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Fake docker: `compose ls` answers from $T/compose-ls.json, the rest is logged.
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "compose ls" ]; then cat "$T/compose-ls.json"; else echo "\$*" >> "$T/docker.log"; fi
EOF
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH" CLAUDE_CONFIG_DIR="$T/claude"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$CLAUDE_CONFIG_DIR"; echo '[]' > "$T/compose-ls.json"; : > "$T/docker.log"

git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/shop" 2>/dev/null
cd "$T/shop"
git commit -q --allow-empty -m init && git push -q origin main
cat > .lanes.conf <<'EOF'
LANES_COMPOSE_FILE=""
LANES_PORTS="APP_PORT=47100"
LANES_GITNEXUS="off"
EOF
port_of() { sed -n 's/^APP_PORT=//p' "$1/.env.local"; }
project_of() { sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$1/.env.local"; }

echo "ports"
git worktree add -q "$T/shop.feat-wt" -b feat/wt            # another tool's worktree, outside shop-lanes/
"$LANES" adopt "$T/shop.feat-wt" >/dev/null
git worktree add -q "$T/shop-lanes/feat-a" -b feat/a
"$LANES" adopt "$T/shop-lanes/feat-a" >/dev/null
check "a lane outside LANES_ROOT keeps its port" '[ "$(port_of "$T/shop.feat-wt")" != "$(port_of "$T/shop-lanes/feat-a")" ]'
git worktree add -q "$T/shop-lanes/feat-b" -b feat/b
git worktree add -q "$T/shop-lanes/feat-c" -b feat/c
"$LANES" adopt "$T/shop-lanes/feat-b" >/dev/null & "$LANES" adopt "$T/shop-lanes/feat-c" >/dev/null & wait
check "parallel adopts get different ports" '[ "$(port_of "$T/shop-lanes/feat-b")" != "$(port_of "$T/shop-lanes/feat-c")" ]'

echo "prune"
cat > "$T/compose-ls.json" <<EOF
[{"Name":"shop-admin","ConfigFiles":"$T/shop-admin/docker-compose.yml"},
 {"Name":"$(project_of "$T/shop.feat-wt")","ConfigFiles":"$T/shop.feat-wt/docker-compose.yml"},
 {"Name":"$(project_of "$T/shop-lanes/feat-a")","ConfigFiles":"$T/shop-lanes/feat-a/docker-compose.yml"},
 {"Name":"shop-feat-gone","ConfigFiles":"$T/shop-lanes/feat-gone/docker-compose.yml"}]
EOF
"$LANES" prune --yes >/dev/null
check "a stack whose lane is gone is removed" 'grep -q -- "-p shop-feat-gone down" "$T/docker.log"'
check "another project with the same prefix is left alone" '! grep -q -- "-p shop-admin " "$T/docker.log"'
check "a live lane outside LANES_ROOT is left alone" '! grep -q -- "-p $(project_of "$T/shop.feat-wt") " "$T/docker.log"'
check "a live lane under LANES_ROOT is left alone" '! grep -q -- "-p $(project_of "$T/shop-lanes/feat-a") " "$T/docker.log"'

echo "sync"
echo '[]' > "$T/compose-ls.json"
git branch feat/later                                        # made to start on later
git switch -q -c feat/done && git commit -q --allow-empty -m "merged work" && git push -q origin feat/done
git switch -q main && git merge -q --ff-only feat/done && git push -q origin main
"$LANES" sync >/dev/null 2>&1
check "a fresh branch without commits survives sync" 'git show-ref -q --verify refs/heads/feat/later'
check "a merged branch is deleted by sync" '! git show-ref -q --verify refs/heads/feat/done'

echo "doctor"
check "without the plugin, the briefing is a FIX" '"$LANES" doctor | grep -q "FIX   SessionStart briefing"'
echo '{"enabledPlugins":{"lanes@xudo-lanes":true}}' > "$CLAUDE_CONFIG_DIR/settings.json"
check "with the plugin enabled, the briefing is ok" '"$LANES" doctor | grep -q "ok    SessionStart briefing"'

echo "plugin hook"
mkdir "$T/plain" && git -C "$T/plain" init -q
check "silent in a repo without .lanes.conf" '[ -z "$(cd "$T/plain" && "$HERE/hooks/session-start.sh")" ]'

echo ""
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

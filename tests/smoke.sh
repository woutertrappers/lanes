#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are read inside check's eval strings
# Smoke tests for lanes. Offline and harmless: a local bare repo as origin and
# a fake `docker` that only logs what it would do.
#   tests/smoke.sh                 # test bin/lanes
#   LANES_BIN=/path/to/lanes tests/smoke.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANES="${LANES_BIN:-$HERE/bin/lanes}"
# A space in every path: lanes must not split them.
TROOT="$(mktemp -d)"; T="$TROOT/${LANES_TEST_DIR:-my projects}"; mkdir -p "$T"; trap 'rm -rf "$TROOT"' EXIT
pass=0; fail=0
ok()   { echo "  ok    $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# Capture output first, then search it: `lanes … | grep -q` lets grep quit
# early, lanes gets SIGPIPE and pipefail turns a match into a failure.
has() { grep -qF -- "$2" <<<"$1"; }

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
out="$("$LANES" doctor)" || true
check "without the plugin, the briefing is a FIX" 'has "$out" "FIX   SessionStart briefing"'
echo '{"enabledPlugins":{"lanes@xudo-lanes":true}}' > "$CLAUDE_CONFIG_DIR/settings.json"
out="$("$LANES" doctor)" || true
check "with the plugin enabled, the briefing is ok" 'has "$out" "ok    SessionStart briefing"'

echo "plugin hook"
mkdir "$T/plain" && git -C "$T/plain" init -q
check "silent in a repo without .lanes.conf" '[ -z "$(cd "$T/plain" && "$HERE/hooks/session-start.sh")" ]'

echo ".lanes.conf is data"
mkdir "$T/evil" && git -C "$T/evil" init -q -b main
cat > "$T/evil/.lanes.conf" <<EOF
touch "$T/pwned-line"
LANES_URL="\$(touch "$T/pwned-subst")"
LANES_COMPOSE_FILE=""  # trailing comment
LANES_DROP_BRANCH=1
EOF
(cd "$T/evil" && "$HERE/hooks/session-start.sh" >/dev/null 2>&1; "$LANES" status >/dev/null 2>&1) || true
check "a plain command in .lanes.conf does not run" '[ ! -e "$T/pwned-line" ]'
check "\$(…) in a value does not run" '[ ! -e "$T/pwned-subst" ]'
out="$(cd "$T/evil" && "$LANES" status 2>&1 >/dev/null)" || true
check "internal variables can't be set from .lanes.conf" 'has "$out" "ignoring unknown setting LANES_DROP_BRANCH"'
printf 'LANES_PORTS="X=a[$(touch "%s/pwned-arith")]"\n' "$T" > "$T/evil/.lanes.conf"
check "a non-numeric port is refused" '! (cd "$T/evil" && "$LANES" status >/dev/null 2>&1)'
check "…and not evaluated" '[ ! -e "$T/pwned-arith" ]'

echo "session start is local"
git clone -q "$T/origin.git" "$T/other" 2>/dev/null
echo x > "$T/other/shared.txt" && git -C "$T/other" add shared.txt && git -C "$T/other" commit -q -m remote \
  && git -C "$T/other" push -q origin HEAD:feat/remote
git -C "$T/other" reset -q --hard HEAD~1 && git -C "$T/other" commit -q --allow-empty -m "news on main" \
  && git -C "$T/other" push -q origin HEAD:main
before="$(git rev-parse origin/main)"
(cd "$T/shop-lanes/feat-a" && "$LANES" status >/dev/null 2>&1)
check "status does not fetch" '[ "$(git rev-parse origin/main)" = "$before" ]'
git fetch -q origin
echo y > "$T/shop-lanes/feat-a/shared.txt" && git -C "$T/shop-lanes/feat-a" add shared.txt && git -C "$T/shop-lanes/feat-a" commit -q -m mine
out="$(cd "$T/shop-lanes/feat-a" && "$LANES" status 2>/dev/null)" || true
check "status runs the overlap check" 'has "$out" "overlap with other lanes"'
check "status checks overlap with lanes only" '! has "$out" "feat/remote shares"'
out="$(cd "$T/shop-lanes/feat-a" && "$LANES" overlap 2>&1)" || true
check "lanes overlap still sees origin branches" 'has "$out" "feat/remote shares"'

echo "rm"
mkdir "$T/shop-lanes/feat-a/docs"
check "refuses a folder inside a lane" '! (cd "$T/shop-lanes/feat-a" && "$LANES" rm docs --force >/dev/null 2>&1)'
check "…and the lane is still there" '[ -d "$T/shop-lanes/feat-a/docs" ]'
check "refuses a folder of another repo" '! "$LANES" rm "$T/plain" --force >/dev/null 2>&1'
"$LANES" rm "$T/shop-lanes/feat-c" >/dev/null 2>&1 || true
check "removes a clean lane by its path, without --force" '[ ! -d "$T/shop-lanes/feat-c" ]'

echo "default branch"
git init -q --bare -b master "$T/legacy.git"
git clone -q "$T/legacy.git" "$T/legacy" 2>/dev/null
git -C "$T/legacy" commit -q --allow-empty -m init && git -C "$T/legacy" push -q origin master
git -C "$T/legacy" remote set-head origin --auto >/dev/null
out="$(cd "$T/legacy" && "$LANES" status 2>&1)" || true
check "status ran in the master repo" 'has "$out" "This session:"'
check "master is found as the default branch" '! has "$out" WARNING'

echo "settings"
sed 's/^# *\(LANES_[A-Z_]*=\)/\1/' "$HERE/skills/lanes/templates/lanes.conf" > .lanes.conf   # every setting, uncommented
out="$("$LANES" status 2>&1 >/dev/null)" || true
check "every setting in the template is accepted" '! has "$out" "ignoring unknown setting"'
printf 'LANES_ROOT="$(dirname "$MAIN")/shop-wt"\nLANES_COMPOSE_FILE=""\nLANES_GITNEXUS=off\n' > .lanes.conf
"$LANES" new feat/rooted --no-up --no-index >/dev/null 2>&1
check "\$(dirname \"\$MAIN\") in LANES_ROOT still works" '[ -d "$T/shop-wt/feat-rooted" ]'

echo ""
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

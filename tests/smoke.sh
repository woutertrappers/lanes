#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are read inside check's eval strings
# Smoke tests for lanes. Offline and harmless: a local bare repo as origin,
# fake `docker` and `gitnexus` that only log what they would do, and no global
# git config.
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
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/gitnexus.log" > "$T/bin/gitnexus"
chmod +x "$T/bin/docker" "$T/bin/gitnexus"
export GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME="$T/xdg"   # a developer's global ignore would hide bugs
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

echo "ls: dirty, activity and the main checkout"
# A repo of its own, without .lanes.conf and with an env file nothing ignores.
git init -q --bare -b main "$T/web.git"
git clone -q "$T/web.git" "$T/web" 2>/dev/null
cd "$T/web"
echo a > a.txt && git add a.txt && git commit -q -m init && git push -q origin main
LANES_ROW="web-lanes/feat-x "
row() { "$LANES" ls --no-fetch | grep -F "$LANES_ROW"; }
col() { row | awk -v n="$1" '{print $(NF - n)}'; }          # from the right: paths have spaces
dirty() { col 1; }
active() { col 0; }
"$LANES" new feat/x --no-up --no-index >/dev/null 2>&1
X="$T/web-lanes/feat-x"
check "the env file lanes wrote does not count as dirty" '[ "$(dirty)" = 0 ]'
check "a fresh lane is active" '[ "$(active)" = "<1m" ]'
out="$("$LANES" ls --no-fetch)"
check "no warning for a clean, current main checkout" '! has "$out" WARNING'
# Age the lane: HEAD moved long ago, then a file changed two hours ago.
reflog="$(git -C "$X" rev-parse --absolute-git-dir)/logs/HEAD"
sed 's/> [0-9]* /> 1000000000 /' "$reflog" > "$T/reflog" && cp "$T/reflog" "$reflog"
ago() { date -d "$1 ago" +%Y%m%d%H%M 2>/dev/null || date -v-"$2" +%Y%m%d%H%M; }
check "an untouched clean lane shows the age of its last HEAD move" '[[ "$(active)" =~ ^[0-9]{4,}d$ ]]'
mkdir "$X/new dir" && echo n > "$X/new dir/n.txt" && touch -t "$(ago '2 hours' 2H)" "$X/new dir/n.txt"
check "an uncommitted file sets the activity" '[ "$(active)" = 2h ]'
check "…and counts as dirty" '[ "$(dirty)" = 1 ]'
echo b >> "$X/a.txt"
check "the newest uncommitted file wins" '[ "$(active)" = "<1m" ]'
touch -t "$(ago '2 hours' 2H)" "$X/a.txt"; echo n > "$X/new dir/z.txt"
check "…also when it is not listed first" '[ "$(active)" = "<1m" ]'
rm "$X/new dir/z.txt"; touch -t "$(ago '5 minutes' 5M)" "$X/new dir/n.txt"
check "minutes are shown as minutes" '[[ "$(active)" =~ ^[4-6]m$ ]]'
rm "$X/new dir/n.txt" && git -C "$X" checkout -q a.txt && rm "$X/a.txt"
check "a deleted file counts as activity" '[ "$(active)" = "<1m" ]'
git -C "$X" checkout -q a.txt && git -C "$X" mv a.txt "renamed file.txt"
check "a staged rename is read as one change" '[ "$(dirty)" = 1 ] && [ "$(active)" = "<1m" ]'
touch -t "$(ago '2 hours' 2H)" "$X/renamed file.txt"
check "a rename that keeps the file time counts as activity" '[ "$(active)" = "<1m" ]'
git -C "$X" mv "renamed file.txt" a.txt
index="$(git -C "$X" rev-parse --absolute-git-dir)/index"
touch -t "$(ago '2 hours' 2H)" "$X/a.txt"; before="$(cksum < "$index")"; "$LANES" ls --no-fetch >/dev/null
check "ls does not rewrite another checkout's index" '[ "$(cksum < "$index")" = "$before" ]'
mkdir "$X/many" && (cd "$X/many" && seq 1 2100 | xargs touch -t "$(ago '2 hours' 2H)")
check "a huge untracked tree is cut off and marked" '[ "$(active)" = "<=2h" ]'
rm -r "$X/many"

echo n > "$T/web/.env.local"                                 # in the main checkout it is yours
out="$("$LANES" ls --no-fetch)"
check "warns about uncommitted changes in the main checkout" 'has "$out" "1 uncommitted change(s) in the main checkout"'
rm "$T/web/.env.local"
git clone -q "$T/web.git" "$T/web2" 2>/dev/null
git -C "$T/web2" commit -q --allow-empty -m elsewhere && git -C "$T/web2" push -q origin main
out="$("$LANES" ls)"
check "warns when the main checkout is behind" 'has "$out" "1 commit(s) behind origin/main — there: git pull --ff-only origin main"'
check "…without sending anyone to sync, which removes lanes" '! has "$out" "lanes sync"'
git switch -q -c side
check "no behind warning when main is on another branch" '! has "$("$LANES" ls --no-fetch)" "behind origin"'
git switch -q main && git branch -q -D side
check "a standalone prune warns too" 'has "$("$LANES" prune 2>&1)" "behind origin/main"'
out="$(cd "$X" && "$LANES" status 2>/dev/null)" || true
check "status shows the warning inside a lane too" 'has "$out" "behind origin/main"'
git commit -q --allow-empty -m local
out="$("$LANES" ls --no-fetch)"
check "warns that a push will be rejected when diverged" 'has "$out" "1 ahead: a push will be rejected"'
check "…and asks before combining them" 'has "$out" "ask the integrator"'
git reset -q --hard origin/main

# Merged elsewhere a moment ago: rm has to see it without anyone fetching.
git -C "$X" commit -q --allow-empty -m feature && git -C "$X" push -q origin feat/x 2>/dev/null
git -C "$T/web2" fetch -q origin && git -C "$T/web2" merge -q --no-ff -m merge origin/feat/x && git -C "$T/web2" push -q origin main
out="$("$LANES" rm feat-x 2>&1)" || true
check "rm fetches, so it deletes a branch merged a moment ago" 'has "$out" "deleted local branch feat/x"'
check "rm points at a main checkout that is behind" 'has "$out" "behind origin/main"'
git pull -q --ff-only origin main

echo "rm and ls: unusual setups"
lane() { "$LANES" new "feat/$1" --no-up --no-index >/dev/null 2>&1; }
conf() { printf '%s\n' "$@" > "$T/web/.lanes.conf"; }
echo .lanes.conf >> .git/info/exclude
lane off; git remote set-url origin "$T/nowhere.git"
out="$("$LANES" rm feat-off 2>&1)" || true
check "rm carries on when the fetch fails, and says so" '[ ! -d "$T/web-lanes/feat-off" ] && has "$out" "WARNING: git fetch failed"'
git remote set-url origin "ext::sleep 60"; lane stall 2>/dev/null || true
GIT_ALLOW_PROTOCOL=ext:file timeout 30 "$LANES" rm feat-stall > "$T/stall.log" 2>&1 || true
check "a stalled fetch does not block rm" '[ ! -d "$T/web-lanes/feat-stall" ]'
git remote set-url origin "$T/web.git"

lane broken; echo x > "$T/web-lanes/feat-broken/work.txt"
echo garbage > "$(git -C "$T/web-lanes/feat-broken" rev-parse --absolute-git-dir)/index"
"$LANES" rm feat-broken >/dev/null 2>&1 || true
check "rm refuses when git status fails" '[ -f "$T/web-lanes/feat-broken/work.txt" ]'
"$LANES" rm feat-broken --force >/dev/null 2>&1 || true

conf 'LANES_ENV_FILE="../shared.env"'; lane outside
echo x > "$T/web-lanes/feat-outside/work.txt"
check "an env file outside the lane does not break ls" '"$LANES" ls --no-fetch >/dev/null 2>&1'
"$LANES" rm feat-outside >/dev/null 2>&1 || true
check "…nor let rm drop uncommitted work" '[ -f "$T/web-lanes/feat-outside/work.txt" ]'
"$LANES" rm feat-outside --force >/dev/null 2>&1 || true

git push -q origin main:develop
conf 'LANES_BASE="origin/develop"'; lane dev
D="$T/web-lanes/feat-dev"
git -C "$D" commit -q --allow-empty -m dev && git -C "$D" push -q origin HEAD:feat/dev 2>/dev/null
git -C "$T/web2" fetch -q origin && git -C "$T/web2" switch -q -c develop origin/develop \
  && git -C "$T/web2" merge -q --no-ff -m merge origin/feat/dev && git -C "$T/web2" push -q origin develop
out="$("$LANES" rm feat-dev 2>&1)" || true
check "rm sees a merge into a custom base" '[ ! -d "$D" ] && has "$out" "deleted local branch feat/dev"'
check "no pull advice because a custom base moved" '! has "$("$LANES" ls)" "behind"'

conf 'LANES_ROOT=".lanes"'; lane inside
check "lanes inside the main checkout are not its uncommitted work" '! has "$("$LANES" ls --no-fetch)" "uncommitted change"'
"$LANES" rm "$T/web/.lanes/feat-inside" >/dev/null 2>&1 || true

rm .lanes.conf; lane opt
conf "LANES_DEFAULT_BRANCH=\"--upload-pack=touch '$T/pwned-fetch';git-upload-pack\"" 'LANES_BASE="origin/main"'
"$LANES" rm feat-opt >/dev/null 2>&1 || true
check "a default branch that looks like an option runs nothing" '[ ! -e "$T/pwned-fetch" ]'
check "…and is refused" '! "$LANES" ls --no-fetch >/dev/null 2>&1'
conf 'LANES_BASE="--output=x"'
check "a base that looks like an option is refused" '! "$LANES" ls --no-fetch >/dev/null 2>&1'
rm .lanes.conf
"$LANES" rm feat-opt >/dev/null 2>&1 || true

git clone -q --bare "$T/web.git" "$T/bare.git"
git -C "$T/bare.git" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$T/bare.git" fetch -q origin
git -C "$T/bare.git" worktree add -q "$T/bare-wt" -b feat/b origin/main
check "ls works with a bare main repository" '(cd "$T/bare-wt" && "$LANES" ls --no-fetch >/dev/null 2>&1)'
(cd "$T/bare-wt" && "$LANES" new feat/c --no-up --no-index >/dev/null 2>&1) || true
check "…and so does rm" '(cd "$T/bare-wt" && "$LANES" rm feat-c >/dev/null 2>&1)'
cd "$T/shop"

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

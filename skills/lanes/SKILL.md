---
name: lanes
description: Run several Claude Code sessions or agents on one repository without collisions — one git worktree, dev stack, database and branch per session, draft PRs as claims, a SessionStart hook that shows who works on what, and an audit of the whole dev process (commit, push, deploy, ssh). Use when the user starts feature work while other sessions may be running, asks to "start a new session/lane/worktree", "work in parallel", "multiple agents on one repo", "who is working on what", "set up lanes", or asks to audit or improve their development process, CI/CD or deploy flow.
---

# lanes

Parallel AI sessions on one repo collide in four places: the working tree (a branch switch
in one window moves the ground under the others), the dev stack (fixed container names and
ports), the database, and shared docs everybody edits. `lanes` gives every session its own
lane and makes the others visible.

The CLI is `lanes`. Installed as a plugin, it is on your Bash PATH (the plugin's `bin/`);
installed with `install.sh`, it is in `~/.local/bin`. If `command -v lanes` fails, it lives at
`../../bin/lanes` from this skill's directory. Hooks in `.claude/settings.json`, git aliases
and the user's own terminal need `lanes` on the real PATH: if it is not there, offer
`git clone https://github.com/woutertrappers/lanes ~/src/lanes && ~/src/lanes/install.sh --cli-only`.

## Decide which mode

- **Work mode** — the repo already uses lanes (`.lanes.conf` exists, or `lanes status` ran
  at session start). Follow the rules below.
- **Setup mode** — the user wants lanes in a repo. Follow "Set up a repo".
- **Audit mode** — the user asks to evaluate or improve their dev process. Follow
  `references/audit.md`.

## Work mode: rules for you as the agent

1. **Read the `lanes status` output** the hook gave you. If you are in the main checkout and
   it is not on the default branch, say so before doing anything else.
2. **Feature work happens in a lane.** If you are in the main checkout and asked to build
   something, run `lanes new <type>/<slug>` and work there (cd into it, or tell the user to
   start the session there). Do not `git checkout` another branch in the main checkout.
3. **After the first commit, claim it:** `lanes claim` (opens a draft PR/MR).
4. **Before editing a widely used file, run `lanes overlap`** and mention any other branch
   that touches it.
5. **Shared docs (task list, plan, agent instructions) are the integrator's.** From a lane,
   put notes in `docs/tasks.d/<branch>.md` or the PR description instead.
6. **Talk to containers through compose in the lane** (`docker compose --env-file
   <env> exec <service> …`), never by a fixed container name.
7. **Code index:** if GitNexus is installed, run `lanes index` after a rebase or large change
   and before impact / detect-changes.
8. **Clean up** with `lanes rm <name>` only when the user says the work is merged or dropped,
   or run `lanes prune` (a dry run) after merges and show its list. Never pass `--force` or
   `--yes` without asking.
9. **Never deploy or touch servers from a lane.** That is the integrator's job.
10. **Before changing a lane that isn't yours, check `ACTIVE` in `lanes ls`.** Recent
    activity means another session may be working there: ask the user, or make your own lane.
    An old value is no proof that it is free (reading and running tests leave no trace).
11. **Pass on the main checkout warnings** that `lanes ls`, `status` and `rm` print (behind,
    diverged, uncommitted changes). Don't pull, commit, stash or run `lanes sync` there
    without asking.

## Set up a repo

1. `lanes doctor` — lists what is missing.
2. Copy `templates/lanes.conf` to the repo root as `.lanes.conf`; fill in the ports, URL,
   database service and bootstrap command from the project's compose file and README.
3. Make the dev compose file lane-safe: remove `container_name:` lines, read host ports from
   env vars (`'${FRONTEND_PORT:-5173}:5173'`), keep in-container ports fixed. If CORS or a
   callback URL hardcodes a port, make it accept any port or read it from env.
4. Session-start briefing: with the lanes plugin installed, nothing to do, its hook runs
   `lanes status` in every repo that has `.lanes.conf`. Without the plugin (or for teammates
   who don't have it), merge `templates/settings.json` into `.claude/settings.json` (keep
   existing hooks) and make sure `.claude/settings.json` is not gitignored. The plugin then
   steps aside, so nobody gets the briefing twice.
5. Add `references/workflow.md` to the repo docs (adapted) and point the agent instructions
   file (CLAUDE.md / AGENTS.md) at it in two lines.
6. Prove it: `lanes new feat/lanes-smoke`, check the app URL, `lanes rm feat-lanes-smoke --force`.
7. Commit on a branch; do not push or merge without the user.

## Integrations

- **Claude Code worktrees.** Merge `templates/settings.worktree-hooks.json` into
  `.claude/settings.json` to make every Claude-made worktree a lane. That covers
  `--worktree`, `EnterWorktree`, subagents with `isolation: "worktree"`, background sessions
  and workflows. Suggest it when the user runs subagents in worktrees. Warn that it replaces
  Claude's default worktree creation, and that `.worktreeinclude` is then ignored (lanes
  copies the env file itself).
- **Worktrunk.** `templates/wt.toml` goes in `.config/wt.toml`: adopt, up and release in
  Worktrunk's hooks. It is untested, so say so.
- **Other tools.** `lanes adopt "$PWD" --up` in their setup script, `lanes release "$PWD"`
  in their teardown.

## Commands

| Command | Does |
|---|---|
| `lanes new <type>/<slug>` | worktree from `origin/main`, own compose project + ports, DB cloned or bootstrapped, code index |
| `lanes ls` | every lane: branch, port, stack, ahead/behind, dirty files, last activity; warns about the main checkout |
| `lanes overlap` | files this branch shares with other open branches |
| `lanes claim` | push + draft PR (GitHub via `gh`) or MR (GitLab push options) |
| `lanes status` | the session-start overview |
| `lanes index` | refresh the GitNexus index of this checkout |
| `lanes up` / `down` / `url` | stack control inside a lane |
| `lanes rm <name>` | fetches, then stack, volumes, images, index and worktree gone; refuses uncommitted or unpushed work |
| `lanes sync` (`git post-merge`) | main checkout after merges: pull, prune lanes and merged branches, reindex; refuses on an unmerged or dirty branch |
| `lanes prune [--yes]` | every merged lane gone (merge, fast-forward or squash via the forge); keeps dirty, fresh and changed-after-merge lanes; also stops orphaned stacks |
| `lanes doctor` | readiness check for the current repo |
| `lanes adopt [dir] [--up]` | lane runtime for a worktree made by another tool |
| `lanes release [dir]` | stop the runtime, keep the worktree |
| `lanes hook worktree-create\|worktree-remove` | Claude Code worktree hooks |

Databases: `--db clone` copies the main checkout's Postgres (roles included) so logins work
straight away; `--db empty` runs `LANES_DB_BOOTSTRAP`; `--db none` skips it.

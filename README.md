# lanes

**Run five Claude Code sessions on one repo, and none of them breaks the others.**

You open a second agent window to fix a bug while the first one builds a feature. Ten minutes
later the first one is on the wrong branch, your dev database is empty because a test suite
ran in the other window, and two sessions rewrote the same task list. `lanes` fixes that by
giving every session its own lane:

- **its own git worktree and branch**, so a branch switch in one window never moves the
  ground under another;
- **its own dev stack**: compose project, containers, network, volumes and host ports;
- **its own database**, cloned from your main dev DB so you can log in at once, or built
  from your migrations;
- **its own code index**, if you use GitNexus,
  so impact analysis sees the code this session actually changed.

Then it makes the other sessions visible. A `SessionStart` hook tells every new session
where it is, which lanes exist, which draft PRs claim which work, and which files it shares
with other open branches, before it writes a line.

It ships as a **Claude Code skill**: the agent knows the rules (feature work in a lane,
claim after the first commit, shared docs belong to one integrator, never deploy from a
lane) and can set lanes up in your repo for you. The skill also includes an **audit of your
whole dev process**: commit, push, pipeline, deploy and ssh. That is the checklist that
found these problems in a real project.

## Quick start

```bash
git clone https://github.com/woutertrappers/lanes ~/src/lanes
~/src/lanes/install.sh            # skill → ~/.claude/skills/lanes, CLI → ~/.local/bin/lanes

cd ~/code/myapp
lanes doctor                      # what this repo needs (usually: drop container_name, env ports)
```

Or ask Claude: *"set up lanes in this repo"*. The skill walks through `lanes doctor`,
writes `.lanes.conf`, makes your compose file lane-safe, adds the hook and proves it with a
throwaway lane.

Daily use:

```bash
lanes new feat/invoice-export     # ../myapp-lanes/feat-invoice-export, stack up, DB cloned
cd ../myapp-lanes/feat-invoice-export && claude
lanes claim                       # after the first commit: draft PR = "I'm on this"
lanes ls                          # all lanes: branch, port, stack, ahead/behind, dirty
lanes overlap                     # who else touches the files you touch
lanes rm feat-invoice-export      # merged? stack, volumes, images, index and folder gone
```

## Commands

| Command | What it does |
|---|---|
| `lanes new <type>/<slug>` | worktree from `origin/main`, compose project `<repo>-<slug>`, ports base+n, DB seeded, code index built |
| `lanes ls` | every lane with branch, port, stack state, ahead/behind, uncommitted files |
| `lanes overlap [branch]` | files shared with other open branches, local and remote |
| `lanes claim [--empty]` | push + draft PR (GitHub, `gh`) or draft MR (GitLab push options) |
| `lanes status` | the overview the session hook prints |
| `lanes index` | rebuild this checkout's GitNexus index |
| `lanes up` / `down` / `url` | stack control inside a lane |
| `lanes rm <name> [--force]` | removes everything; refuses uncommitted or unpushed work |
| `lanes doctor` | readiness check: compose file, ports, env file, CLIs, hook |
| `lanes adopt [dir] [--up]` | give a worktree made by any tool its lane runtime |
| `lanes release [dir]` | stop a lane's runtime, keep the worktree |
| `lanes hook worktree-create\|worktree-remove` | Claude Code `WorktreeCreate` / `WorktreeRemove` hooks |

## Configuration

One file, `.lanes.conf` at the repo root, all optional:

```bash
LANES_PORTS="FRONTEND_PORT=5173 BACKEND_PORT=3000"   # lane n gets 5174/3001, 5175/3002, …
LANES_EXTRA_ENV='FRONTEND_URL=http://localhost:${FRONTEND_PORT}'
LANES_URL='http://localhost:${FRONTEND_PORT}'
LANES_DB_SERVICE="postgres"                           # enables --db clone|empty
LANES_DB_BOOTSTRAP="run --rm --no-deps backend npm run db:migrate"
```

See [`templates/lanes.conf`](skills/lanes/templates/lanes.conf) for every setting.

## How a team works with it

One **integrator** session stays in the main checkout on `main`. It merges, edits the
shared docs (task list, plan, `CLAUDE.md`) and deploys. Every **feature** session works in
its own lane and writes notes to `docs/tasks.d/<branch>.md` instead of the shared files.
Read-only research sessions can run anywhere. The full guide is
[`references/workflow.md`](skills/lanes/references/workflow.md); drop it into your repo.

## The audit

Ask Claude to *"audit our dev process"* and the skill scores 22 practices across parallel
sessions, commits, pipeline, deploy and servers. Examples:

- whether staging really gates production;
- whether a laptop deploy can ship unmerged files;
- whether your hooks are actually installed;
- whether two deploys can run at once.

Every finding comes with evidence and a concrete fix. It only reads; it never changes
settings. See [`references/audit.md`](skills/lanes/references/audit.md).

## Works with the tools you already use

lanes doesn't need to own your worktrees. Whatever makes them, lanes adds the runtime and
the coordination.

**Claude Code worktrees (built in).** Add
[`templates/settings.worktree-hooks.json`](skills/lanes/templates/settings.worktree-hooks.json)
to `.claude/settings.json`. Every worktree Claude Code creates then becomes a lane. That
covers `claude --worktree`, `EnterWorktree`, subagents with `isolation: "worktree"`,
background sessions and workflows:
- a random name like `bold-oak-a3f2` becomes branch `agent/bold-oak-a3f2`;
- `feat-auth` becomes `feat/auth`;
- each lane gets its own ports and env file, plus a code index;
- the stack only starts when you ask (`LANES_HOOK_UP=1`), so subagents stay fast;
- when Claude removes the worktree, lanes refuses if there is uncommitted or unpushed work;
  otherwise it removes everything, branch included.

**Worktrunk.** Let Worktrunk create and switch worktrees, and let lanes run inside its hooks.
[`templates/wt.toml`](skills/lanes/templates/wt.toml) runs `lanes adopt` in `pre-start`,
`lanes up` in `post-start` and `lanes release` in `pre-remove`. *(Written from Worktrunk's
hook docs; not yet tested end to end, so reports are welcome.)*

**Anything else** (desktop orchestrators, kanban boards, plain `git worktree add`): put
`lanes adopt "$PWD" --up` in the tool's setup script and `lanes release "$PWD"` in its
teardown script.

## Related tools

Worktrees for parallel agents are a well-known pattern, and good tools exist:

- **Claude Code** itself has `claude --worktree <name>`, and `.worktreeinclude` copies
  ignored files such as `.env` into new worktrees.
- **[Worktrunk](https://github.com/max-sixty/worktrunk)** manages worktrees with hooks,
  build caches and a port per worktree.
- **[git-worktree-runner](https://github.com/REN-100/git-worktree-runner)** and
  **[agent-worktree](https://github.com/nekocode/agent-worktree)** are CLI managers.
- Board- and desktop-style orchestrators run one agent per worktree.

lanes doesn't try to replace them. It covers what a worktree alone leaves open:

- **runtime isolation**: a compose project, a database clone and a code index per lane;
- **coordination**: draft PRs as claims, file overlap between open branches, a session-start
  briefing, and one writer for the shared docs;
- **the rest of the process**: the audit.

It is a small bash script plus a Claude Code skill, so you can read every line.

## Requirements

- bash, git 2.20+ (worktrees);
- for dev stacks: Docker Compose v2 and Postgres if you use `--db`;
- optional: `gh` (GitHub draft PRs), `glab` (listing GitLab drafts), GitNexus.

Tested on Linux and WSL2. macOS should work (it needs `ss`, or edit `port_taken`); reports
welcome.

## License

MIT. See [LICENSE](LICENSE).

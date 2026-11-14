# The lanes way of working

Several AI coding sessions on one repository, without collisions. Copy this into your
repo as `docs/dev-workflow.md` and adjust the names.

## Roles

| Session | Folder | Does |
|---|---|---|
| **Integrator** (one) | the main checkout, on `main` | merges, edits the shared docs (task list, plan, agent instructions), deploys, touches servers |
| **Feature** (as many as you need) | `../<repo>-lanes/<type>-<slug>` | code on one branch, own dev stack and database, pushes that branch |
| **Research / review** | anywhere | reads only |

Never switch branches in the main checkout for feature work: other sessions live there too.

## Start a session

```bash
lanes new feat/short-name      # worktree from origin/main + stack + copy of your dev DB
cd ../<repo>-lanes/feat-short-name
claude                         # or your agent of choice
```

The `SessionStart` hook prints `lanes status`: where this session is, every lane, open
draft PRs, files you share with other open branches, and a stale code index. Act on its
warnings before you write code.

## While you work

- **Claim the work** after your first commit: `lanes claim` pushes and opens a draft PR/MR.
  The list of drafts is the board of who is doing what.
- **Small conventional commits** (`feat(scope): …`, `fix: …`). No `update`, no `git add .`.
- **Stay current:** `git fetch && git rebase origin/main` at least daily. Never merge one
  feature branch into another.
- **Check overlap** before touching something big: `lanes overlap`.
- **Shared docs have one writer.** Task lists, plans and agent instructions (`TASKS.md`,
  `CLAUDE.md`, …) are edited by the integrator only. A feature session writes its notes in
  `docs/tasks.d/<branch>.md` or the PR description; the integrator merges them.
- **Code index:** with GitNexus installed every lane has its own index. Run `lanes index`
  after a rebase or a large change.

## Done

1. Mark the draft ready; wait for a green pipeline.
2. The integrator merges, pulls `main` in the main checkout, refreshes its index.
3. `lanes rm <name>` removes the stack, volumes, images, index and folder. It refuses while
   work is uncommitted or unpushed.

## Shared things outside git

Deploys, staging and production servers are touched by the integrator only, one at a time.
Put a lock with an owner on anything two sessions could otherwise run at once (CI
`resource_group`, `flock` on the server).

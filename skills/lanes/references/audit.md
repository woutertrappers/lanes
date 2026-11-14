# Dev-process audit for AI-assisted teams

Score each item **ok / partial / missing / n/a**, cite `file:line` or the command that
shows it, then report gaps ranked by risk: secrets and deploy safety first, speed last.
Mark what can only be seen in the forge UI (protected branches, required pipelines, masked
variables, registry cleanup) as "unverified — check in GitHub/GitLab", or read it with
`gh api` / `glab api` when the CLI is logged in. Read-only: never change settings yourself.

## A. Parallel sessions

1. **One checkout per session.** `git worktree list` shows more than one line when several
   sessions run. One line + several open agent windows = they share a working tree.
2. **The dev stack can run twice.** No `container_name:` in the dev compose file, host ports
   from env vars (`lanes doctor`).
3. **Separate databases per session.** A shared dev DB plus a test suite that empties it is
   a collision waiting to happen.
4. **Claims are visible.** Draft PRs per running session; a `SessionStart` hook that shows
   them.
5. **Shared docs have one writer.** Look for concurrent edits of task lists and agent
   instruction files (`git log --format='%h %ad %s' -- TASKS.md`), merge commits between
   feature branches, the same commit message twice with different hashes.
6. **The code index sees the session's checkout** (GitNexus or similar): one index per
   worktree, or the agent's impact analysis reads stale code.

## B. Commit and push

7. **Hooks installed**, not just configured: `.git/hooks/pre-commit` exists (secret scan),
   plus `commit-msg` (conventional commits) and a block on committing to `main`.
8. **No junk commits:** count `update` / `wip` messages on `main`; look for files committed
   by `git add .` (stray names in the root).
9. **Main is protected:** nobody pushes directly; merges need a green pipeline; squash with a
   conventional title.

## C. Pipeline

10. **Secret scan first**, same version as the local hook.
11. **Tests against real services**, including the way production builds its schema
    (migrations, roles, row-level security), not a shortcut like `db push`.
12. **One immutable image per commit** (tag = commit SHA); `latest` moves only on `main`.
13. **Caching, `interruptible`, timeouts**; frontend lint + tests; dependency and image scans.

## D. Deploy

14. **A deploy is a button, pinned to the SHA** of the pipeline it belongs to, not `latest`.
15. **Staging gates production** (`needs: [deploy-staging]`), not just by habit. Check the
    deployments API: a production deploy in the same minute as a failed staging deploy
    means there is no gate.
16. **One recipe for CI and laptop**, but the laptop path refuses a dirty tree or a branch
    other than `origin/main` (it often ships files from the working tree).
17. **One deploy at a time**, also between laptop and CI (lock on the server, not only a CI
    `resource_group`).
18. **Smoke test at the end** that fails the deploy, including the invariants a health
    endpoint can't see (e.g. "the app role still sees its data").
19. **Runbook matches the pipeline** (tags, rollback steps).
20. **Image cleanup** on the server and a registry cleanup policy that keeps the rollback window.

## E. Servers

21. **Ad-hoc ssh is wrapped:** read-only commands through a small wrapper; anything that
    writes asks first and names the target.
22. **Agent guardrails:** deny rules for `git push … main`, destructive database commands,
    `docker rm` over ssh; allow rules for the read-only wrapper commands.

## Report format

A table (item, status, evidence), then the gaps by risk, each with a concrete fix and
whether it is code in the repo or a click in the forge. Don't restate compliant items.

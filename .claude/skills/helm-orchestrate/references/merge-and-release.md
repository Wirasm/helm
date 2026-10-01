# Merge and release

## Before a PR enters the queue

An agent's report says where its proof is; it is not the proof. Check:

```text
gh pr view <n> --json state,isDraft,baseRefName,headRefOid,mergeable
gh pr checks <n> --required
```

- Open, not draft, base `development`.
- A published `READY TO MERGE` review whose report's reviewed head is the current `headRefOid`, or a head
  that only merged `development` in since. A clean base update keeps the verdict; a conflict
  resolution needs a review of the resolution only (`prp-orchestrate` has the patch-id check).
- Required checks green on that head.
- The operator has said this run may merge. Agents never merge.

`MERGEABLE` is a claim about text, not about compiling: two PRs once merged cleanly and did not
build. The queue's per-head CI after its update-branch is what catches that.

## The merge queue

`development` requires an up-to-date head and three green checks (`build · test · format`,
`skill gates`, `fmt · clippy · build · test`), so merges are serial: each one leaves every other
PR behind. The Archon workflow `helm-merge-queue` does the update-branch, waits for CI on that
exact head, merges with `--match-head-commit`, and verifies the merge commit. It is the only merge
path. Its README is `.archon/workflows/helm/merge-queue/README.md`; read it once.

```text
Q=<repo>/.worktrees/merge-queue          # once: git -C <repo> worktree add --detach .worktrees/merge-queue origin/development
git -C "$Q" fetch -q origin && git -C "$Q" checkout -q --detach origin/development
archon workflow status --cwd "$Q" --json                                  # a queue already running?
archon workflow run helm-merge-queue --cwd "$Q" --input prs="<n> <n>" --detach --json
archon workflow wait <runId> --timeout <seconds> --json
archon workflow get <runId> --json | jq '.status, .terminal_record.returns.value'
```

- The order you give is the order it merges. Lowest risk first; a stack bottom to top.
- A run takes about five minutes per PR that needs CI. `wait` exits 0 when the run ended (read
  `status`: a failed run also exits 0), 3 when the timeout passed.
- A second launch while one runs is cancelled, not queued. PRs that become ready mid-run go in the
  next batch.
- Read the report and act on each key:
  - `merged`: log it, clean up (below). `pruned` says which of their worktrees the queue
    removed, and for each one it kept, why: a process in it, uncommitted work, commits
    `development` does not have.
  - `held` with a conflict reason: mail the owner the catch-up brief, requeue when green.
  - `held` on a red check after one re-run: a real failure or a flake. Read the log; send it to
    the owner.
  - `landed_through`: its head is already in `development` (usually through the PR above it in a
    stack). Check, then close it with "landed through #<n>".
  - `unverified`: `development` moved and nobody checked how. Stop and look before the next batch.
  - `queued`: never reached because the run stopped; send them again.

## Release

Release after a batch merges, so the operator runs what was merged. Build from a detached
checkout of `origin/development`, never from a worktree with work in it:

```text
git -C <repo> worktree add --detach <repo>/.worktrees/release origin/development   # once
git -C <repo>/.worktrees/release fetch -q origin && git -C <repo>/.worktrees/release checkout -q --detach origin/development
```

**helm only** (no `daemon/` change since the last release): `make -C <repo>/.worktrees/release
release`. It builds, stamps and signs the bundle and tells the running helm, which shows an
update badge in the status bar. The operator clicks it when he chooses. Every pane is a benchd
session, so nothing ends. Never quit his helm yourself.

**benchd too** (a `daemon/` change): benchd must be rebuilt and restarted, and a restart ends
every session, every workstream's and yours too when you run in a helm pane. So this half is the
operator's to run: when no workstream is mid-turn, mail him that the release is ready and send
him these commands. He runs them from the release checkout in a terminal that is not a benchd
session, such as Ghostty outside helm (`just benchd-install` refuses with `BENCH_DIR` set, which
every bench session has):

```text
just benchd-install      # cargo install bench and benchd, restart the login agent, browser back
make release             # then the badge, as above
just resume-all          # every recorded agent resumed in its pane, every other pane a shell
```

`just release-resume <session-id>` was the one-command form for an operator who is away. Since
M5b it refuses every session in a helm pane (it requires the session to descend from helm's
process, and pane sessions descend from benchd's), so do not reach for it until that is fixed.

After a release, mail each resumed workstream where it stands.

## Clean up after a merge

The queue removes the worktrees of the PRs it merged (`pruned` in its report). After every batch,
prune the rest, and look at each one the script keeps:

```text
just -f <repo>/justfile prune-worktrees --dry-run      # what would go, and why each other stays
just -f <repo>/justfile prune-worktrees
git -C <repo> branch -d <branch>
```

It never removes a worktree with a process in it, a tracked change, untracked files or commits
`development` lacks. Close the workstream's pane (`bench close <pane> --force`) once nothing
more is needed from that agent. Each worktree holds 3-4 GB of builds, and about sixty of them
filled the disk on 2026-10-01.

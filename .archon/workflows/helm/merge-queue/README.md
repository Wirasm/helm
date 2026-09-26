# helm merge queue

`helm-merge-queue` lands pull requests on `development` one at a time. It is a prototype.
It exists to replace the orchestrator's scratchpad merge script, and to learn what shape a
merge queue in Archon should take (coleam00/Archon#3211, parked). It is small on purpose and
built for this repository only. Expect it to change.

## What one run does

It takes the PR numbers in the order given. The orchestrator owns the order. For each PR:

1. If the PR's head is already in `development`, close it as landed through another PR
   (`landed_through`). This is the stacked case where the PR above carried it.
2. If the PR is stacked on a branch whose PR has merged, retarget it to `development`. If
   that PR is still open, hold it.
3. If it conflicts with `development`, hold it. If it is behind, run `gh pr update-branch`.
   That is a merge, not a rebase, so the reviewed commits keep their SHAs.
4. Wait until every check that branch protection requires has passed on **that exact head
   SHA**. The required names come from the protection API, not from this file. A red check
   holds the PR. If a check has not appeared three minutes after the head appeared, the queue
   closes and reopens the PR once, because a retarget does not start CI.
5. Merge with `gh pr merge --merge --match-head-commit <head>`, then read the PR back. It must
   be MERGED, and the merge commit's parents must be exactly `[development tip before the
   merge, head]`. If the PR did not merge, it is held. If it merged with any other parents, it
   is `merged_unverified`. Either one **stops the batch**, and the remaining PRs stay
   `queued`, because the next update would build on a base nobody checked.

A held PR does not move `development`, so the next PR carries on. Each PR has 50 minutes
before it is held as `timeout`. `mode=preview` does steps 1-4 and stops at `tested`.

State: `queue.json` in the run's artifacts. Across runs, one line per transition goes to
`~/.archon/workspaces/Wirasm/helm/state/merge-queue/ledger.jsonl`.

## Run it

Archon refuses a second run on a working path while one is live. That limit is the queue's
concurrency control, so the queue runs from a checkout of its own. Set it up once:

```bash
git -C ~/Projects/mine/sild/helm worktree add --detach .worktrees/merge-queue origin/development
```

Then, for each batch:

```bash
Q=~/Projects/mine/sild/helm/.worktrees/merge-queue
git -C "$Q" fetch -q origin && git -C "$Q" checkout -q --detach origin/development
archon workflow status --cwd "$Q" --json          # is a queue already running there?
archon workflow run helm-merge-queue --cwd "$Q" --input prs="412 413" --detach --json
archon workflow wait <runId> --json               # blocks until it ends
archon workflow get <runId> --json | jq '.status, .terminal_record.returns.value'
```

`wait` exits 0 when the run has an answer, 3 when `--timeout` passed with the run still
going, and 1 when the wait itself failed. A failed run also exits 0, so read `status`.
The answer is the `report` node:
`{mode, base_sha, merged, tested, landed_through, held, queued, reasons, stopped, summary}`.
`queued` lists PRs the run never reached (it stopped first). `reasons` maps a PR number to
why it was held.

A launch while a queue is live does not queue behind it. Archon cancels the new run
(`precondition_failed`, "This worktree is in use"). Check `status` first, and send the PRs
that arrive mid-run in the next batch.

Progress for a live run: `archon workflow logs <runId> --follow`.

## Gate

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .archon/workflows/helm/.shared
archon validate workflows helm-merge-queue
```

The three decisions are plain functions in `.shared/merge_queue.py` and are tested without
GitHub: `checks_at`, `next_move` and `verify_merge`. The rest is `gh` calls around them.

## Two prototypes: what each tried, and what we are learning

The first queue is `sasha-merge-queue` in the Sasha project. Neither is the right answer yet.
This table is the input for the Archon design.

| Question | Sasha tried | helm tries | Why helm differs, and what a run will tell us |
|---|---|---|---|
| Who tests the composed tree? | The queue: `git merge-tree` builds a candidate and the local gate runs on it | The forge: `update-branch` builds it, and the required CI checks test it | helm's Swift gate needs vendored libghostty, and two suites need a display. `development` also only accepts a head that is up to date. Tells us whether a queue can own no gate at all and only sequence and verify. |
| Test all, then merge | Tests the whole chain, then an approval, then merges the lot | Tests and merges one PR before touching the next | Strict protection makes testing ahead impossible: the base the next PR needs does not exist until this one merges. Costs one CI run (about 5 min) per PR, serially. Tells us the real batch time. |
| What pins the merge | `--match-head-commit`, plus the tree landed on `dev` equals the tested tree (squash) | `--match-head-commit` on the head the checks passed on, plus the merge commit's parents | helm merges with `--merge`, so commits, not only trees, are the identity. Tells us whether a parent readback is enough, or whether a tree check is still worth having. |
| Checks | Its own gate's exit code | Branch protection's required contexts, latest run per name, at the exact head SHA | The scratchpad script read `gh pr checks` without a SHA and once went on past a PR that did not merge. Tells us whether a per-SHA read plus `mergeStateStatus` is enough. |
| Stacked PRs | Out of scope ("land one, rebase the next, queue it") | Retargets once the lower PR merged; closes a PR whose head already landed | helm stacks PRs often. Tells us whether stack handling belongs in the queue or before it. |
| Batches vs per PR | One batch per run; the path lock keeps it to one run | Same | Archon's trigger admission could queue per-PR runs, but needs two Archon changes (`trigger fire --input`, and a drain after `trigger execute`). Tells us whether batches are painful enough to want them. |
| Ordering and judgment | An agent orders and assesses; a policy file decides auto-landing | None: the order given, no agent, no approval node | The orchestrator already reviewed and decided (it is the approval). Tells us whether a queue needs its own judgment when the caller already has it. |
| Report | `{base_sha, tested, held, merged, summary}` plus a board and dashboard from the ledger | The same keys plus `landed_through`, `queued`, `reasons`, `stopped`; ledger only, no board | The caller is an agent that acts on the result, so reasons and the stop point are in the value rather than in prose. |
| Repair | A spend-gated agent repairs conflicts | None: a conflict is held for the PR's owner | Keeps the prototype small. |

Findings from real runs go to the research note that started this:
`~/.prp/helm-3ec376fc/research/archon-merge-queue-2026-09.md`.

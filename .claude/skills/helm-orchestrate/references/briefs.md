# Briefs

A spawned agent knows only its brief, the repo's `AGENTS.md`, and the skills its harness can see.
The brief is a file in the run's folder (`$PRP_DIR/orchestration/<run-id>/<handle>.md`), passed
with `--prompt-file`. Keep it short: the work, the skills and when to use each, the report
contract. Do not restate rules `AGENTS.md` already gives every agent.

## Naming a skill, per harness

The templates below are written for claude. For codex or pi, rewrite every skill line in them
from this table, including "using the bench-mail skill" in the common block. The task should still
read as plain language; the skill name tells the agent which procedure to load.

| Harness | prp skill | helm skill |
|---|---|---|
| claude | `Use the prp-core:prp-issue skill` | `the bench-mail skill` (inside the helm repo) |
| codex | `Use $prp-issue` | `Read and follow <helm>/.claude/skills/bench-mail/SKILL.md` |
| pi | not available as a chain; give the steps in the brief | `Read and follow <helm>/.claude/skills/bench-mail/SKILL.md` |

`<helm>` is `/Users/rasmus/Projects/mine/sild/helm`. `references/harnesses.md` says which skills
each harness sees, and how to check.

## The block every brief carries

```text
You are <handle> on the bench, in run <run-id>. Your orchestrator is <orchestrator handle>.

Work in <absolute worktree path> on <branch>, created from origin/development. Run
`git rev-parse --show-toplevel` before any git command and stop if it is not that path.
<For PR work:> Open the PR against development. Do not merge it.

Report by mail, using the bench-mail skill:
  bench mail send --to <orchestrator handle> --subject "<handle>: <done|blocked|broken>" --body-file <file>
Send one when you finish (the artifact and its proof), when only the operator or I can decide
something (the decision and your recommendation), and when something broke that you cannot fix.
Nothing else reaches me, and nothing reaches you except mail: no notification arrives for CI, a
review, or another agent. Poll what you wait for with a bounded command, for example
  timeout 1800 gh pr checks <n> --required --watch --fail-fast
(its exit code says green, red or timed out), and never end a turn waiting for a message nobody
will send.

Before every report mail, delete your worktree's builds: `rm -rf <worktree>/.build
<worktree>/daemon/target` (3-4 GB; sixty worktrees' builds filled the disk once). The next gate
run rebuilds them if I send you back.

Bound everything you start with `timeout`. A test-drive of benchd or helm runs against its own
root: BENCH_DIR=$(mktemp -d) (you inherited the live one, and it wins over BENCH_SUITE).

Other workstreams in flight, and the files they touch: <map, or "none">.
```

## Delivery (prp-issue)

```text
<common block>

Use the prp-core:prp-issue skill on <issue URL, or the operator's request verbatim>.
It plans with prp-plan, implements and opens the PR with prp-implement, reviews in a fresh
context with prp-review, fixes, and waits for green CI. Review weight: <docs only: no review
agent | small change: one prp-core:code-reviewer | wire format, daemon state, isolation or data
loss: code-reviewer, seam-analyzer and house-rules-auditor>.

Operator context that changes this work: <his words, verbatim, or "none">.

When the review says READY TO MERGE on the current head and the required checks are green, mail
me the PR URL, its head sha, the review report path and its URL. Then stay: I will mail you
if the PR needs a rebase or a fix before it merges.
```

## Spike (prp-spike)

```text
<common block, without the PR line>

Use the prp-core:prp-spike skill to answer: <one falsifiable question>.
What would change the plan: <the decision this verdict feeds>.
Build the smallest throwaway thing that could prove it wrong, in this worktree. No PR.
Mail me the verdict (PROVEN, DISPROVEN or CONDITIONAL), the evidence, and the report path.
<When the question came from an issue:> Post the verdict on <issue> as the skill says.
```

## Review

The delivery owner normally runs its own review. Spawn a separate reviewer when the operator wants
an independent one, or a second model family.

```text
<common block, with a detached checkout instead of a branch:>
Work in <absolute path of a detached checkout of the PR head>. Do not edit files there.

Use the prp-core:prp-review skill on PR <n>, scopes: <code | code, seam, rules>. Read the linked
plan and implementation report. Publish the review to the PR, then mail me the verdict, the
reviewed head sha, the report path and its URL. Do not push or modify the PR.
```

Create the detached checkout first:
`git -C <repo> worktree add --detach <repo>/.worktrees/review-<n> <head sha>`. A reviewer in the
owner's worktree once wiped the owner's uncommitted work.

## Fix after review

Send this as mail to the delivery owner, whose context still holds the plan and the code. Spawn a
new agent only when the owner is gone.

```text
Review of PR <n> at <sha>: <verdict>, report <path or URL>.
Fix what matters now: blocking and important findings, and simplifications in code this PR
touches. Decline taste or wrong findings with a one-line reason on the PR. File unrelated
discoveries as issues. Do not run another full review to confirm routine fixes; ask for a scoped
re-review only when a fix changes behaviour, a wire format, state or isolation.
Worktree: <absolute path>; check `git rev-parse --show-toplevel` first.
Mail me the new head sha and green checks when done.
```

## Catch-up after a merge

Each merge leaves the other PRs behind `development`. When the queue holds a PR on a conflict:

```text
PR <n> conflicts with development after <merged PR> (<files>). In <worktree>: merge
origin/development, resolve keeping both sides' intent, run the gate, push. A conflict resolution
gets a review of the resolution only. Mail me the new head when CI is green.
```

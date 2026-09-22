# Quick delivery prototype

An SDLC-pack workflow being tested in Helm before promotion to Archon. It contains
no Helm paths, toolchain commands, provider choices or model IDs. It uses current
Archon workflow primitives and the bundled `archon-pr` component; tested against
Archon source revision `adbe23426`.

Quick means fewer steps. The implementer uses `large` and the reviewer uses
`medium`, matching the full SDLC pack. Either tier can resolve to any operator-chosen
model through ordinary Archon configuration. No automatic downgrade or fallback.

## Run

From a checkout containing this folder:

```sh
archon workflow list archon-quick-deliver --full
archon workflow run archon-quick-deliver --branch fix/my-change \
  --config /absolute/path/to/model-config.yaml --detach \
  "The problem, value, why now, outcome, invariants and acceptance criteria"
```

Use `--workflow-source /path/to/authoring-checkout` when the workflow lives in a
separate worktree from the repository being changed. Use `--from` and `--base` to
select the starting revision and PR target. Model config is optional when the
operator's existing bindings are appropriate. Never copy another operator's
credentials or replace their default Archon configuration.

## Behavior

1. Implement and run the repository's required local gate. Record the result in
   `implementation.md` under the run's artifacts, then commit the intended change.
2. One fresh reviewer checks correctness, scope, simplicity, interface contracts
   and whether tests prove the outcome. It writes `review.md`. It can run a focused
   check to resolve a doubt, but does not repeat the full gate by default.
3. Correct and re-review when needed, with at most three total attempts. Source
   changes invalidate affected validation; unchanged valid evidence can be reused.
4. Open a draft PR using the pack's PR component. Probe GitHub CI every 30 seconds,
   bounded to 21 probes. Re-read checks and the reviewed revision before making
   the PR ready; read the draft state back after the mutation. Never merge.

There is no separate intake, plan, review classifier, specialist fan-out, synthesis,
PR-body resynchronization, or unconditional final local validation.

## Deliberate limits of this first version

- Select it explicitly for a decided, bounded change. An unresolved decision or
  need for broad investigation stops implementation with a report.
- Required local checks must pass. Unlike full delivery, this first version does
  not authorize publication on inherited or environment-red local checks.
- CI must actually register. No checks, missing access, pending CI beyond the bound,
  failed/cancelled checks, or a changed PR revision cannot become a success.
  Repositories without CI need another workflow until a deliberate no-CI contract
  is added.
- Review corrections are automated; CI failures leave a draft PR and fail with
  evidence for operator-directed correction. No hidden repair run starts.
- A pre-PR failure leaves the local branch and run artifacts, not a public PR.
- Timing from a single replay is exploratory. Provider interruptions, compilation,
  CI queues, and concurrent work must be reported separately from step reduction.

## Validate

```sh
archon workflow test archon-quick-deliver
bun test ./.archon/workflows/sdlc/quick-deliver/scripts/ci.test.ts
```

Fixtures execute the real implementation/acceptance gates in isolated scratch
worktrees. They cover accepted work and refusal before publication. Archon's dry
runner assumes `until_bash` completion, so the review-blocked fixture proves the
final acceptance gate, not live multi-round convergence. The live Helm replay
exercises the real executor. CI script tests inject GitHub responses, including
red, cancelled, pending, missing and malformed results; they do not contact GitHub.

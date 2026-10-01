# Run: {run-id}

> Kept by the orchestrator for the run's life, in `$PRP_DIR/orchestration/{run-id}.md`, with the
> briefs in `$PRP_DIR/orchestration/{run-id}/`. Live state is benchd's, GitHub's and Git's; this
> file is what lets a fresh orchestrator pick the run up. Rewrite the tables in place. The Event
> log is append-only and stays the last section, so a launch can be appended with `>>`.

**Concern**: {what the operator entrusted to the run, in his words}
**Status**: active | complete | abandoned
**Orchestrator**: {your handle, or "no mailbox"}
**Base**: development
**Started**: {YYYY-MM-DD HH:MM}

## Outcome

{Filled at close, from verified state: what shipped with PR links, then anything that needs the
operator: decisions, handed-back work, risks, cleanup left. "Nothing needs the operator." when
nothing does.}

## Workstreams

| Handle | Task | Skill | Harness · model · effort | Worktree · branch | PR | State |
|---|---|---|---|---|---|---|
| ws1 | {issue or request} | prp-issue | claude · opus · high | .worktrees/{name} · {branch} | - | running |

State is one of `queued`, `running`, `blocked`, `ready` (READY TO MERGE and green), `merged`,
`verdict:<PROVEN|DISPROVEN|CONDITIONAL>`, `dropped`, `handed-back`.

## Standing decisions

A standing decision answers a question that will come up again ("For the rest of this run, ...").
Only the operator makes one. Rewrite a row in place when he changes it, and log the change.

| SD | Decision | Source | At |
|---|---|---|---|
| SD-1 | Base branch is `development` | operator | {HH:MM} |
| SD-2 | {e.g. the orchestrator merges a PR once its current head has a published READY review and green CI} | operator: "{his words}" | {HH:MM} |

## Event log

One line per durable event: a launch (appended by the spawn snippet, with the session, runtime
id and pane), a gate answer, steering that changed a workstream, a block, a queue run, a merge, a
release, a terminal state. Stamp each with `date +%H:%M`, and the date when it changes.

- {HH:MM} run started

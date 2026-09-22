# Review the completed change independently

Work order: $INPUTS.work

Operator request: $ARGUMENTS

Review the current committed change at $revision.output.head against the starting
commit recorded in $ARTIFACTS_DIR/quick-start-sha. Read the repository guidance and
$ARTIFACTS_DIR/implementation.md, then verify the complete diff and relevant callers
and tests yourself. Prior rounds are in $ARTIFACTS_DIR/review.md when present.

You are the one independent reviewer. Judge correctness, accepted scope, unnecessary
complexity, broken type/interface contracts and whether the tests prove the outcome.
Use the repository's engineering conventions. A finding needs a reachable failure
and precise source evidence; discard speculation and preference. Pay particular
attention to tests that would also pass for the old or a plausibly wrong behavior.

Implementation owns the full local gate. Verify its recorded commands, results,
validated revision and limits. Do not rerun the entire suite merely to duplicate
that evidence. A focused check is appropriate when it can settle a specific doubt.
Do not edit source, tests or the checkout, and do not commit, push or post remotely.
Only write $ARTIFACTS_DIR/review.md. It must identify the reviewed revision and give
concrete findings with the smallest correction, or state why the change is ready.

For a subsequent round, verify dispositions and inspect the correction delta and
its affected behavior. Do not restart four specialist reviews or restate settled
findings. If the outcome requires a product/design decision, say so explicitly.
Return ready=true only if no actionable blocker remains and required validation
supports this revision. Suggestions alone need not block. Return ready=false with
a concise explanation otherwise; the implementer receives your written report.

Return head as the exact reviewed revision $revision.output.head.

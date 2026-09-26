# Implement the bounded work

Work order: $INPUTS.work

Operator request: $ARGUMENTS

Both apply; the operator's explicit scope and constraints take precedence. If the
work order is empty, use the request. No work in either means stop, ready=false.

Read repository guidance and any engineering.md it points to, the affected code,
callers and tests. Read linked issue context when it changes the contract. Verify
claims against current code. If this needs a product decision, unknown-cause
investigation or broad redesign, do not invent one: explain what is needed in
$ARTIFACTS_DIR/implementation.md and return ready=false. Quick changes workflow
ceremony, never the correctness bar or model capability.

The starting commit is in $ARTIFACTS_DIR/quick-start-sha. On correction rounds,
read $ARTIFACTS_DIR/review.md and your previous implementation.md. Fix demonstrated
findings, or rebut them with concrete evidence. Stay on the existing branch and
within the accepted outcome; do not turn adjacent discoveries into extra work.

Implement the smallest coherent change. Reproduce the bug or establish direct
source evidence first. Add focused tests where they prove changed behavior; for
regressions, demonstrate red against the original behavior and green with the fix.
Keep relevant comments and documentation accurate. Do not add tests for trivia.

You own local validation. Run the repository's required gate once on the finished
change; targeted checks during iteration do not replace it. Repeat affected checks
and any repository-required full gate after corrections change source. Reuse valid
recorded evidence when neither the tested content nor relevant environment changed;
never claim a test ran again if it did not. Do not change or delete a check to make
it pass. A blocker or unresolved failing required check means ready=false, even
when it predates this change: name it and preserve evidence for the operator.

Commit the intended changes by named paths with human-written messages. Never
push, open a PR, merge, install or deploy; downstream owns PR publication. Preserve
unrelated changes. Leave no intended changes uncommitted.

Write a concise $ARTIFACTS_DIR/implementation.md: outcome, exact commands and
results, regression proof, validated commit, corrections/dispositions and remaining
limits. This is the validation handoff, not an additional plan or task checklist.
Return ready=true only when the requested outcome is complete, committed and
verified; otherwise false with a concrete summary. There is no hidden fallback to
another workflow or model.

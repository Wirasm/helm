# Publish the reviewed change as a draft

The publication check resolved this target. Use it exactly:

Repository: $INPUTS.repository
Branch: $INPUTS.branch
Reviewed commit: $INPUTS.head
Base branch: $BASE_BRANCH

Operator request, for outcome and scope: $ARGUMENTS

This job publishes only the checked repository and current branch. Never select a
PR by a number in the request or by ambient GitHub context. Do not adopt a fork PR,
push another branch, retarget origin, or switch checkouts. If the request needs a
different target, stop and record why in $ARTIFACTS_DIR/publication.md.

Verify HEAD equals the reviewed commit, the current branch equals the checked
branch, and the tree is clean. Read the complete diff against the base and the
implementation.md and review.md artifacts. Do not edit or commit source. Validation
and independent review are already complete; do not repeat them.

Find an open PR using `gh pr list --repo <repository> --head <branch> --state open`
and read its qualified head/base and draft state. Reuse only a same-repository PR
whose head is exactly this branch and whose base matches. An existing ready PR is
a refusal: do not push or silently return it to draft. More than one matching PR
or a cross-repository match is also a refusal. Preserve the evidence in
publication.md rather than guessing.

Write a concise PR title and body to $ARTIFACTS_DIR using the repository's template
when present. Explain the problem, outcome and actual validation; no invented
claims, AI attribution, or implementation inventory. Respect the operator's issue
closure instructions. Use --body-file so prose is never interpreted by the shell.

Push exactly HEAD to the checked branch on origin, without force. For a new PR use
`gh pr create --repo <repository> --head <branch> --base <base> --draft`. For an
existing draft update that exact PR's body/title if necessary, retaining draft
status. No ready flip, merge, deployment, issue edits or comments.

Read the PR back by its number with the explicit repository. Verify it is open,
draft, same-repository, has the checked head branch at the reviewed commit, and
targets the expected base. Return its qualified identity only after that read-back:
repo.host=github.com, repo.path=<repository>, number, url, head=<branch>, base,
is_draft=true. A failed publication must not produce a fabricated PR result.

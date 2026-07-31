# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues on `Wirasm/helm`. Use the `gh` CLI for all
operations — it infers the repo from `git remote -v` when run inside a clone.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body-file <file>`. Prefer `--body-file` over
  `--body` for anything multi-line: the default shell here is fish, where heredocs do not behave the
  way the surrounding docs assume.
- **Read an issue**: `gh issue view <number> --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body-file <file>`
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

Note `gh issue edit` does **not** accept `--jq`; it prints the issue URL and nothing else.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> --comments` and `gh pr diff <number>` for the diff.
- **List external PRs for triage**: `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments` then keep only `authorAssociation` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE` (drop `OWNER`/`MEMBER`/`COLLABORATOR`).
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either — resolve with `gh pr view 42` and fall back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

**Both native mechanisms are verified working on this repo** (2026-07-31) — sub-issues and issue
dependencies. The fallback conventions the generic template describes (task lists, `Part of #<map>`,
a `Blocked by:` line in the body) are **dead branches here**; do not use them.

- **Map**: a single issue labelled `wayfinder:map`, holding the Destination / Notes / Decisions-so-far /
  Not-yet-specified / Out-of-scope body. `gh issue create --label wayfinder:map`.
- **Child ticket**: an issue attached to the map as a GitHub sub-issue:
  `gh api --method POST repos/Wirasm/helm/issues/<map>/sub_issues -F sub_issue_id=<child-db-id>`.
  Note this takes the child's numeric **database id**, not its `#number`, and it returns the *parent*
  issue on success. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
- **Blocking**: GitHub's **native issue dependencies** — the canonical, UI-visible representation, so
  the frontier renders in GitHub itself without opening the map. Add an edge with
  `gh api --method POST repos/Wirasm/helm/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`,
  where `<blocker-db-id>` is the blocker's numeric **database id**
  (`gh api repos/Wirasm/helm/issues/<n> --jq .id`, _not_ the `#number` or `node_id`).
- **Frontier query**: a ticket is on the frontier when it is open, has `issue_dependencies_summary.blocked_by == 0`,
  and has no assignee. Read all three from `gh api repos/Wirasm/helm/issues/<n>`. Beware: that REST
  endpoint reports `state` in **lowercase** (`"closed"`), while `gh issue view --json state` reports it
  uppercase (`"CLOSED"`) — comparing the wrong case silently misclassifies closed tickets as open.
- **Claim**: `gh issue edit <n> --add-assignee @me` — the session's first write, before any work.
- **Resolve**: `gh issue comment <n> --body-file <file>`, then `gh issue close <n>`, then append a
  context pointer (gist + link) to the map's Decisions-so-far.

### Where wayfinder artifacts go

**Not into this repo.** The workspace rule in `../sild/AGENTS.md` is that artifacts — plans, research,
reports — live in the project's `~/.prp/<key>/` store and never in the repos. helm's store is
`~/.prp/helm-3ec376fc/` (`reports/` for research output, `plans/` for plans).

This **overrides** the wayfinder skill's own instruction to capture research findings on a throwaway
`research/<name>` branch. Write the ticket body so it names the `~/.prp/helm-3ec376fc/` destination
explicitly — a research subagent follows the ticket, not the skill.

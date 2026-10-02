---
name: helm-orchestrate
description: Run a fleet of agents on the operator's bench as his orchestrator. Pick claude, codex or pi and a model for each task, spawn each agent into a pane with a brief that names the skills to use, track the fleet with bench sessions and a run file, land the PRs through the Archon merge queue, and release. Use when the operator says "orchestrate these", "spawn agents for these issues", "run these in parallel", "be my orchestrator", "drive the fleet", or "resume the run" in helm, or before starting a second agent for a workstream.
---

# Orchestrating on the bench

A workstream here is an agent process in a benchd pane, with its own worktree, handle and
mailbox. It outlives the orchestrator, the operator can watch it and mail it directly, and other
agents can reach it. That is the gain over a subagent. The cost is that nothing reports for it:
the orchestrator reads its state from benchd, GitHub and Git.

The judgment is `prp-orchestrate`'s: the intake gate, standing decisions, verifying an agent's
proof instead of trusting its report, merge order. Apply it. Its launch mechanics (the Agent tool,
SendMessage, native task status) are what this skill replaces.

The `bench` CLI is on your PATH or named by `$BENCH`. The `bench-panes`, `bench-mail` and
`bench-sessions` skills cover each verb used here.

## 1. Open the run

1. Find your own handle, so agents can mail you: `$BENCH_HANDLE` in a session benchd spawned,
   else `bench mail who --pane "$HELM_PANE"` in a helm pane. With neither, you have no mailbox and
   nothing can wake you. Wait on your agents with `bench watch` instead (step 5).
2. Create the run file `$PRP_DIR/orchestration/<YYYY-MM-DD-slug>.md` from this skill's
   `templates/run.md`, not prp-orchestrate's: the spawn snippet appends launches to the end of the
   file, which is where this template keeps its Event log.
   `$PRP_DIR` is the project's prp store (`~/.prp/<key>/`; any prp skill's resolver finds it).
3. Gate once with the operator: a table of workstream, skill, harness and model, dependencies,
   and what runs in parallel. Record his answers as standing decisions. Then drive the run
   without asking again. A pause costs the whole time he is away.

## 2. Pick the harness and model

Read `references/harnesses.md` before the first spawn of a run. The short version, verified
2026-10-01:

| Job | Spawn |
|---|---|
| Delivery (`prp-issue`), and anything touching wire formats, daemon state, isolation or data loss | `--agent claude --model opus --effort high` |
| Spike, plan, debugging | `--agent claude --model opus --effort high`, or `--agent codex --model gpt-6-sol --effort high` for a second opinion from another model family |
| Mechanical work: a rebase, conflict catch-up, a doc fix | `--agent claude --model sonnet --effort medium` or `--agent codex --model gpt-6-luna` |
| A question about an agent's work | `--fork <its runtime session>`, with its own `--agent`: a read-only copy, and the author is not disturbed |
| A model only pi reaches, or work on pi itself | `--agent pi --model <provider/id>` |

Model names change. Verify a name with the one-line check in the reference before spawning a
fleet on it: codex starts with any name and fails at its first turn, inside the pane.

## 3. Give each workstream a worktree

```text
git -C <repo> fetch -q origin
git -C <repo> worktree add -b <branch> <repo>/.worktrees/<name> origin/development
```

Branches are `feat/<issue>-<slug>`, `fix/<issue>-<slug>` or `spike/<slug>`. Create the worktree
before the spawn and keep it until the PR merges, or until a spike's verdict is in. One agent per worktree, never the
shared checkout. A worktree under the repo inherits Claude Code's trust of the repo, so a
`claude` spawn there does not stop at the trust question.

## 4. Brief, spawn, record

Write the brief from `references/briefs.md` into the run's folder (a file that outlives the
spawn: the agent reads it as its first act). The brief names the skills to use and when, and how
to report. Then spawn and append the launch to the run file:

```bash
BENCH="${BENCH:-bench}"
OUT=$("$BENCH" spawn --agent "$AGENT" --model "$MODEL" --effort "$EFFORT" \
  --cwd "$WORKTREE" --name "$WS" --prompt-file "$BRIEF") || exit
printf '%s' "$OUT" | python3 -c '
import json, sys, time
d = json.load(sys.stdin)
print("- %s launched %s: %s %s, session %s, runtime %s, pane %s" % (
    time.strftime("%H:%M"), d["handle"], d["agent"], sys.argv[1], d["session"],
    d["runtime_session"] or "-", d["pane"]))
' "$MODEL" >> "$RUN"
tail -1 "$RUN"
```

- `$RUN` is the run file's absolute path and `$BRIEF` the brief's (write `$HOME`, not `~`, inside
  quotes). `$WS` becomes the agent's mail handle (`--name`), such as `ws1` or `issue-186`; a taken
  one is refused.
- The answer carries `handle`, `agent`, `session`, `pid`, `runtime_session`, `pane` and
  `workspace`. `runtime` is the conversation id `--resume` and `--fork` take later; a new codex has
  none until its hook records its thread id.
- The pane lands in the background of `$WORKTREE`'s workspace. A few seconds after the spawn, read
  it once with `bench get screen <pane>`: an agent stopped at a trust question or an unknown
  model shows there, not in the spawn's exit code.

## 5. Watch without waiting

Nothing wakes you except mail. A notification you are waiting for that nobody sends is the
most common way a run stalls, for you and for the agents you spawned. Each brief tells its agent
to mail you when it finishes, blocks or breaks. Between mails, read the fleet from the repo root
(the workspace is the repo and all its worktrees):

```bash
BENCH="${BENCH:-bench}"
OUT=$("$BENCH" sessions --all) || exit
printf '%s' "$OUT" | python3 -c '
import json, sys, time
now = time.time() * 1000
for r in json.load(sys.stdin)["rows"]:
    if not r["mail"]:
        continue
    s = r["state"]
    a = s.get("activity") or {}
    what = a.get("kind", s["kind"])
    if a.get("waiting_for"):
        what += " (" + a["waiting_for"] + ")"
    if r["done"]:
        what += " done" + ("" if r["done"]["seen"] else ", unseen")
    print(r["mail"]["handle"], r["harness"], what,
          "%dm" % ((now - r["updated_at_ms"]) / 60000),
          "unread=%d" % r["mail"]["unread"])
'
```

- `waiting` after a finished turn is healthy. `waiting (permission prompt)` for many minutes is a
  stall: no posture removes some guardrails (#283). Read the pane with `bench get screen <pane>`
  and tell the operator; do not add flags.
- codex and pi report their activity through their hooks. `bench log <runtime>` says what any of
  them did, and `bench get screen <pane>` what a pane shows now.
- `unread` that keeps growing means the agent is not reading its mail.
- `done` means the agent's last turn ended and it has not started another. `unseen` means the
  operator has not looked at its pane since; one you spawned is yours to act on, not his.
- To wait on one agent, `bench watch <handle> --timeout <s>` blocks without a model turn until it
  waits on the operator, finishes a turn, or its session ends, and prints which (`outcome`) with
  its `bench sessions` entry. After you mail it new work, pass the `done.since_ms` you last saw
  as `--after <ms>`, or the turn before answers for the next one. With no mailbox of your own,
  this is how you hear from the fleet; run it in the background, one per agent you wait on.
- **Never end a turn waiting for a notification.** No CI result, review, merge-queue verdict or
  agent report arrives by itself, and a turn that ends to wait for one stalls the run until the
  operator notices. Wait with a bounded command (`bench watch <handle> --timeout <s>`, `timeout
  1800 gh pr checks <n> --required --watch`, `archon workflow wait <runId> --timeout <s>`), and end
  a turn only when the run is done or needs the operator.

## 6. Steer

- `bench mail send --to <handle> --from <you> --subject ... --body-file ...` reaches the agent at
  its next tool call, or starts a turn when it is idle. `--from` is needed in a helm pane; a
  session benchd spawned signs with its own `$BENCH_HANDLE`. The operator may mail it directly
  too.
- Restate the worktree path in any instruction that leads to git commands.
- An agent whose session ended while its pane stayed is brought back with `bench restore <pane>`:
  a recorded claude, codex or pi conversation is resumed there. `bench sessions --all` shows
  the handle to mail. When the pane is gone too, spawn again with `--resume <runtime>` (codex: its thread id), or
  a fresh agent whose brief points at the branch and the PR.

## 7. Verify, merge, release

When an agent reports done, verify as `prp-orchestrate` says: an open PR on `development`, a
published `READY TO MERGE` review whose report names the current head as the one it reviewed, and
green required checks. A spike is done when its report exists and its verdict rests on something
it ran. Then land it
through the merge queue and release, as `references/merge-and-release.md` says. Merge only when
the operator has said the run may.

## 8. Close

After a workstream's PR merges, or a spike's verdict is read, end its agent. An agent spawned
into a worktree has a workspace tab of its own, and `bench close` never closes a workspace's last
pane, so close the tab: `bench workspace close <worktree path> --force` (it ends the agent's
session; the folder and branch stay). An agent in a pane of a shared workspace: `bench close
<pane> --force`. Then remove its worktree and add a terminal line to the run file. The merge queue
removed the worktrees of the PRs it merged that nobody was still working in (its report's `pruned`
says which it kept and why; an agent still in its pane keeps its worktree); run `just
prune-worktrees` after every batch for the rest, and `git worktree remove --force
.worktrees/<name>` for a spike's throwaway code. Fill the run file's
outcome section, and send the operator one message with what shipped and what needs him.

## Recover after a restart

Reload the newest run file, then reconcile it against `bench sessions --all`, `gh pr list` and
`git worktree list`. After a benchd restart every session ended: `just resume-all` resumes every
recorded agent in its pane, and each starts with benchd's resume notice: carry on where you were,
re-arm what you had running. Mail an agent only when its state or next step has changed.

## Safety rules

- **The operator's live bench is not a test fixture.** An agent that test-drives benchd or helm
  sets `BENCH_DIR=$(mktemp -d)`: a spawned agent inherits the live `BENCH_DIR`, and it wins over
  `BENCH_SUITE`. A worktree helm runs under `HELM_DEFAULTS_SUITE`.
- **Builds fill the disk.** Every worktree holds 3-4 GB of `.build` and `daemon/target`, and
  about sixty of them filled it on 2026-10-01. Agents delete theirs when they report (the brief
  says so), the queue prunes what it merged where nobody is working, and you prune after every batch. `just check`
  refuses to start below 20 GB free.
- **Everything spawned is bounded.** `timeout` on every long command and every poll loop. Check
  `ps -Ao pcpu,etime,pid,command -r | head` before reporting, and say what is still running.
- **Kill only a pid you verified is yours,** never a pattern. Never quit or restart the
  operator's helm or benchd without his go.
- **Never copy an Apple system binary to fake an executable.** If a fresh binary will not start,
  or `git` hangs, stop launching processes and tell the operator.
- **Agents do not merge.** Only the orchestrator merges, through the queue, under the operator's
  go. Say it in every brief: an agent once merged two PRs despite being told not to.
- **Reviewers read a detached checkout,** never the owner's worktree: a reviewer's
  `git checkout HEAD --` once wiped an owner's uncommitted work.
- **Every verb lands in the background.** Use `--asked` only when the operator asked.
- **No AI attribution** in commits or PRs.

## Resources

- `references/harnesses.md` — per harness: model names, effort levels, resume and fork, which
  skills it can see, how its mail and state work, and how to verify a model name. Read before the
  first spawn.
- `references/briefs.md` — the brief every agent gets, and templates for a delivery, a spike, a
  review and a fix after review. Read before writing a brief.
- `references/merge-and-release.md` — verifying a PR, the Archon merge queue, conflict catch-up,
  the release, and cleanup. Read before the first merge.
- `templates/run.md` — the run file. Read before opening a run.

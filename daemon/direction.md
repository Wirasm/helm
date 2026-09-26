# direction — the bench daemon

An entry point, not a spec — the same posture as helm's `docs/direction.md`. The full
argument lives in `../docs/future-planning/workbench-audit-2026-08.md`; the milestone
sequence in `../docs/future-planning/bench-roadmap.md`. This file is what a session that
just opened `daemon/` needs to hold in its head.

## What this is

`benchd` is the headless Rust daemon helm grows into: it will own everything that must
survive — ptys, VT state, the workbench document, mail, tasks, the attention queue, the
event log — while the SwiftUI app thins into a face that renders daemon state. The
operator and the agents are equal owners; every verb exists in an addressed, non-seizing
form; both parties go through the same socket. Migration is strangler-style inside this
repo: one vertical at a time, old code unwired only when the new is proven.

**Where it stands: M0 + M5a + mail + the shared browser + the bench document's daemon half.** The daemon owns the mailroom (`bench-mail`:
files are the record, notices carry the path never the body, retire-never-delete,
metadata-only listings) and delivery by the recipient's own state (#358, below): nothing is
typed into a pty, and the loop cap is a per-recipient token bucket on the turns benchd starts —
where helm #320 proved it must live.

**Plus the shared browser (#350).** `browser/start|status|stop|setup`: the daemon starts
one browser per root — Google Chrome where installed (the operator's ruling: it runs the
Claude in Chrome and Codex extensions), else Playwright's Chrome for Testing;
`browser/config.json` swaps binary or flags — headless, persistent profile under
`<root>/browser/profile`, debugging port chosen by Chrome and read back from
`DevToolsActivePort`, endpoint published in `<root>/browser/endpoint.json`. `setup` opens
the same profile in a plain Chrome window for installing extensions and signing in: no
user-agent override, no debugging port, because Google refuses sign-in to a browser that
has them (#374). Quitting it returns to headless. The daemon never automates the browser: agents attach with
`playwright-cli attach --cdp=<cdp>`, helm renders it over its own CDP socket. A crash is
restarted (at most 3 in 60s, then `browser/gave-up`), and the browser runs on a pipe
leash so it dies with the daemon even under SIGKILL. `just browser-proof` is the live check.

**And it runs at login (#407).** `just benchd-install` (root justfile) loads benchd as a user
LaunchAgent, `com.wirasm.benchd`: started at login, restarted by launchd after a crash or a kill,
left down after a clean `bench stop`, output in `~/Library/Logs/benchd.log`. benchd decides
whether the browser comes back: `<root>/browser/wanted` is written when a browser starts and
removed only by `browser/stop`, so a daemon that boots and finds it logs `browser/resuming` and
starts the browser again. Only the live instance is installed; `just launchd-proof` bootstraps a
suite-labelled agent from a temp plist, kills benchd with `-9`, requires both to come back, and
boots it out.

**And the bench document (M4, #354), daemon side.** `bench-doc` is helm's `Workbench` —
workspaces, columns, slots, panes, typed surfaces, placement as data — and benchd serves it:
the layout verbs (`workspace/*`, `pane/*`, `focus/*`, `layout/resize`, `drawer/toggle`,
`bench/get`), each logged as one `bench/changed` event that says who asked; `bench.json` as the
record it boots from; and `events --follow`, one line per event with the whole document attached when it
changed. The focus rule is the document's own: an agent's verb that would move the operator's
focus is refused unless it says `asked`. helm does not use any of it yet — its client is the
next step — and `just bench-proof` drives a whole session through the socket and across a
restart.

**Drawers are in the document (#356).** A drawer is a named holder of tabbed panes beside the
workspaces, shown over the bench rather than in it; one is open at a time. `drawer/toggle` opens
or closes one, and `pane/open` takes a `drawer` to put a pane in one. Which drawer is open is the
operator's focus, so an agent's toggle is refused without `asked`, and an agent's pane badges the
drawer instead of opening it. No drawer operation touches a workspace. `bench.json` is version 1
from here, so an older benchd quarantines it rather than dropping drawers on its next save.

**Placement is the operator's file (#356).** Where a new pane goes is a table, and the table is
TOML: the built-in one is `crates/bench-doc/rules/placement.default.toml`, embedded at build
time, and `<root>/rules/placement.toml` replaces it whole. benchd reads the file before each
`pane/open` and each `status` and adopts it only when its text changed, so an edit applies to
the next open with no restart and no watcher. A strategy can send a pane to a drawer
(`{ drawer = "browser" }`). A file that cannot be read, or holds no rules, changes nothing: the
last good table stays in force, `rules/rejected` names the file and why (with the line, for a
parse error) once per version, and `bench status` reports `rejected` until a good version
replaces it. Only a file that is gone means the built-in table. benchd never writes a rules
file. `rules/keymap.toml` beside it is helm's alone: benchd never reads a key.

**The just layer is one verb, `just/run` (#356).** A recipe from `<root>/rules/justfile` is a
composition of `bench` verbs, and benchd runs it rather than helm, so it is logged and dies with
the daemon: `just --justfile <root>/rules/justfile --working-directory <cwd> <recipe>`, with
`BENCH_DIR` (and `BENCH_SUITE`) pointing every `bench` inside it back here. The operator's run
works at the active workspace and gets `BENCH_ASKED=1`, which makes the CLI send `asked`; an
agent's (`bench just`) works where it was asked from and gets nothing, so its verbs are judged
as the agent's. `just/started` is logged before the answer, which does not wait; a reaper logs
`just/finished` with the exit code; output goes to `<root>/just/<run>.log`. The child is on the
browser's pipe leash. A name outside `[A-Za-z0-9_-]`, a missing justfile or a missing `just`
(looked for on `PATH`, then Homebrew's two prefixes) is refused by name.

**And the session list (#384), daemon side.** `bench sessions --all` answers, per workspace,
every agent session helm or benchd hosts: agents in helm panes (matched by pid through helm's
snapshot, or by the pane their own hooks report), benchd's own sessions, Claude Code `--bg` jobs, running subagents, and finished
sessions — the last only from `sessions/hosted.json`, benchd's record of what it and helm
hosted, because no harness file says where a session ran. `bench sessions dismiss` hides a
finished row. helm's drawer is the next step.

**And the sensor (#358, first half of M2 finish).** `bench hook <claude|codex|pi>` is one
command wired into an agent's own hooks. On every event it reports the agent's state over the
socket (the `hook` verb), and the reply carries the agent's unread mail as pointer lines, which
Claude and codex put in front of the model as hook context: a busy agent gets its mail at the
next tool call, with nothing typed into a pty. The first event of a session helm or benchd
declared (`HELM_PANE`, `BENCH_SESSION`) and that runs on a terminal claims its address, recorded
in `sessions/hosted.json` so it survives a restart. A session resumed in another pane keeps its
handle, and its record moves to the pane it reports from under the same rule (`mail/moved`); one
resumed outside helm keeps its handle and mail, and its old pane stops answering for it. An
idle agent is started through its own channel instead: benchd posts the notice to a Claude
session's inbox socket (which its hooks
report), and a push that starts no turn in 10 s goes back to the inbox. A spawn hands its prompt
over in argv as a pointer, so nothing waits for a TUI to draw. pi's channel is its `bench` extension
(`pi/extensions/bench`), which reports through `bench hook pi`, watches the inbox benchd names
and starts its own turn when benchd agrees. An agent the operator starts himself
reports once its harness is wired to the one fixed command: `bench wiring` prints what to add
to the three files and `bench wiring --check` says what is missing. A codex benchd spawns runs
its TUI against an app-server of its own (`codex --remote`, one per session, leashed to the TUI),
which is where its hooks run and where benchd starts a turn (`turn/start`) when it is idle; a
codex the operator starts himself embeds its app-server, so its mail waits for its next prompt
or tool call. `just mail-ring` is the proof: claude, codex and pi pass a number around through
benchd, idle and busy, with per-hop latency from the log. helm
keeps no mailroom of its own since: it asks benchd who is in a pane (`mail/who`) and sends a
canvas note through `mail/send`.

**And the wire front (M3, #355): `bench` is the agent's whole surface.** The CLI speaks the
pane verbs — `open`, `split`, `show`, `focus`, `move`, `name`, `close <pane>`, `get pane` — as
the socket's own layout verbs, carrying who asked (`HELM_PANE`, `BENCH_HANDLE`) and `asked` only
from `--asked`. benchd adds the rules the spool kept at the verb boundary: an agent's close of a
terminal needs `force` (a live session's name is in the refusal; a helm-hosted terminal is opaque
until M5b), a chosen name needs `rename`, and an agent's pane opens in its own workspace. `spawn`
now puts the agent in a pane: the document's terminal surface names the session
(`term:<session>`), and helm shows it by running `bench attach` in that pane, which follows the
pane's size (`resize`) and ends when the session does. No session outlives its daemon, so boot
clears every pane's `session` (`bench/sessions-ended`). What only helm can do — drawing its window
— benchd asks for: `helm/ask` logs `helm/asked` to the followers, helm answers with `helm/answer`,
and the caller waits at most `HELM_ASK_WAIT`. The `bench-panes` skill is the agent's guide.

**Where it stood before mail: M0 + M5a.** A suite-aware record root, an append-only event log, one
unix socket, eight verbs, a CLI speaking helm's exit-code discipline, and a conformance
gate that runs the real binaries. M5a is the pty core: `spawn` puts a real interactive
agent (claude, codex, pi — the allowlist) into a daemon-owned pty with posture, model
and effort flags spelled once in `bench-session`, prompt by file, runtime session id
minted at spawn; `attach` is a dtach-grade raw relay with ring replay and Ctrl-\ detach;
`close` is drain-then-die; `resume` re-enters an exited session where the runtime mints
its id (claude, pi — codex refuses with the reason). Nothing helm does today is owned
here yet; mail is next, waking agents by pasting into ptys this daemon now owns.

## The spine

Three commitments, made now, that every later milestone builds on rather than beside:

**1. Bench-visible means logged.** The append-only event log (`events.jsonl` under the
record root) is the single source of truth. Every mutation appends its event *before*
the response that reports it; snapshots, queues, and "what happened overnight" are
projections of the stream, never a second store. helm's `snapshot.json` becomes a
projection at M4; the silent parked-workspace canvas drop (found 2026-08-17) is the
class of bug this rule deletes — an offer in the log with no consumer is a visible fact,
not a `return` in a guard.

**2. One door.** The socket is the only way in. The CLI, the face, every agent, and the
operator's own keystrokes (from M4) use the same verbs through the same gateway — so
"equal owners" is mechanically true, not aspirational, and there is no privileged
in-process path for a capability to grow attached to. helm accreted six spool kinds, an
OSC push channel, mail hooks in two runtimes, and a snapshot file — each individually
argued, collectively sixteen ropes and no spine. The seventh capability here is a verb
and an event kind, not a new channel.

**3. One spelling of every shared rule.** `bench-wire` holds the wire types AND the
resolution rules (suite names, record roots, request ids, caps). Both binaries compile
against it, so they cannot drift; anything outside the workspace that later needs these
types — the Swift face — gets a generated copy or a conformance-pinned duplicate under
the repo's honest-duplicate rule, never a hand-written one.

## Learned from the field, on purpose

DeepSeek Harness (dsh, studied 2026-08-17 — canvas in the helm prp store) is the most
complete existing implementation of a log-first agent daemon, and three of its ideas are
adopted here deliberately:

- **The logged-envelope invariant.** dsh logs the full model request before dispatch, so
  every request is a pure function of the log, and an independent checker rebuilds and
  compares. Ours is the bench-shaped analog: every response's claim must be derivable
  from the record — `stop` is logged before it is answered, and the conformance suite
  reads the file, not the daemon, to verify history.
- **Caps are reported, never silent.** dsh documents every truncation; `events` returns
  `total`/`returned`/`truncated` from day one, because a capped read that looks complete
  is how "covered everything" gets believed.
- **Refusals name the route.** helm's spool refusals already point at the tool to use
  instead; dsh's tool errors are typed and self-describing. Every refusal here names the
  rule it applied and, where one exists, what to do about it.

And one of dsh's ideas is **rejected** with equal deliberation: the plugin kernel.
benchd serves one operator whose gate is the pull request; composability-as-product
(profiles, patch layers, realm isolation) is generality this estate does not need and a
complexity bill dsh's own five-day-old ecosystem is already paying. Capabilities land as
code in this workspace, reviewed, behind the one door.

## Posture: the agents are smart

Adopted 2026-08-18, the operator's words made a rule. **We expose capabilities; we do
not parse prose.** Nothing in the bench regexes, keyword-matches, or otherwise
reconstructs meaning from human- or agent-written text — a reply is read by an agent,
not by a parser. Interpretation belongs to the model; determinism belongs at the tool
boundary (validated verbs, newtypes, exit codes), which is where `SuiteName` and
`RequestId` already sit. Concretely: the daemon never parses a mail body; notices point
rather than quote; status comes from taps — the runtimes' own typed hook and event
channels — and a capability that seems to need output-scraping is a missing tap or a
missing verb, not a regex waiting to be written. The one deliberate exception the
roadmap names: a last-resort output-classification fallback for a runtime with no tap
at all (M1, codex) — status inference only, never intent, retired the day the tap
exists. The spike harnesses' READY/NOOP markers were test instrumentation, not a
pattern to copy into the product.

## Rules that bind every milestone

The checklist form is bench-roadmap.md's invariants; the ones already load-bearing in
this workspace:

- **Suites isolate or refuse.** `BENCH_SUITE=<name>` moves socket, root, and every byte
  of state; a name that cannot isolate stops the launch — never a fallback to the
  operator's live `~/.bench` (helm #86/#285, ported as `SuiteName`).
- **Files are the record.** Everything persistent is a file a plain `cat` can read;
  sockets are transport, never the only copy.
- **Exit codes are the contract**: 0 ok · 2 no daemon · 3 refused · 4 daemon failed —
  helm's spool codes, kept, because every agent skill in this repo already reads them.
- **Validated newtypes at the edges** (`SuiteName`, `RequestId`), with the standing
  carve-out: a request is decoded permissively in shape and judged strictly afterwards,
  so malformed input earns a refusal naming the reason, not a dropped connection.
- **No orchestrator concept, ever** — no role, rank, or team field in the daemon, the
  wire, or the CLI (roadmap invariant 2). Hierarchy is prompts and skills, run *on* the
  bench.
- **Conformance over trust**: every wire contract gets a test that runs the real binary
  as a subprocess and checks both directions, every status case.

## How it grows

Landed: M0 skeleton, M5a daemon ptys, mail, the shared browser (#350), and M4's daemon half
(the bench document in benchd: #367, #373). Next, in order (tracking issue #362): the rest of
M4, helm as the document's client → M2 finish, one mailroom (helm's mail hooks become sensors) →
M3 `bench` as the whole agent surface → drawers, keymap and rules → M1 attention → M5b every pane a benchd session
→ M6 sync the record over Tailscale → M7 the agents' own machine. Each milestone: new event
kinds, new verbs, same spine. The roadmap is the sequence; the operator names the milestone
that starts.

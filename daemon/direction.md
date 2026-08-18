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

**Where it stands: M0 + M5a + mail.** The daemon owns the mailroom (`bench-mail`:
files are the record, notices carry the path never the body, retire-never-delete,
metadata-only listings) and the wake reactor (`mail/sent ⇒ agent/woken` by pasting into
an idle pty the daemon owns, with the loop cap as a per-recipient token bucket in the
courier — where helm #320 proved it must live). Proven end to end by `just mail-proof`:
a number passed as mail around a real claude→codex→pi ring, +1 per hop.

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

M1 attention queue + taps (first new capability, purely additive) → M2 mail authority →
M3 the CLI replaces the spool scripts → M4 the workbench document → M5 ptys → M6 reach
over the tailnet → M7 the forge. Each milestone: new event kinds, new verbs, same spine.
The roadmap is the sequence; the operator names the milestone that starts.

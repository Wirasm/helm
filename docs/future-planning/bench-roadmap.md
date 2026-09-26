# bench roadmap — the strangler migration, milestone by milestone

**Read this cold.** This document assumes no prior context. The full argument — audit,
landscape research, architecture, decisions and their rationale — is
`docs/future-planning/workbench-audit-2026-08.md` (same directory); read it before starting any
milestone. This file is the actionable sequence: what to build, in what order, what
proves each step, and what gets unwired when.

**The one-paragraph vision.** helm evolves into "the bench": a headless Rust daemon
(`benchd`) owns everything that must survive — ptys, VT state, the bench document,
mail, the event log — and the SwiftUI app becomes a window that renders daemon state and
turns keys into verbs. The operator and the agents go through the same door, `bench
<verb>`, and an agent's verb lands in the background unless the operator asked for it.
Later, a second machine (the forge) runs the same daemon so agents get their own
always-on box; the two share the record as a synced folder. Migration is strangler-style
inside this repo: one vertical at a time, old code unwired only when the new is proven.
**The target shape — seven primitives, the focus rule, drawers and rules, who owns what,
and the terminal stack — is `bench-architecture.md`, approved 2026-09-25. Read it before
this file.**

**Everything is built and proven on one machine — the operator's Mac — first.** The
second machine is not added until M0–M6 are done and living well in daily use; do not
stand up a forge, a VM, or a remote peer "to test peering" before then. The design is
machine-count invariant on purpose (topology is config), so nothing in M0–M6 needs a
second machine to be built correctly — M6 (Sync) makes the Mac's record a synced
folder and proves show-requests as files; it does not add a machine — and `BENCH_SUITE`
gives every isolation the early milestones need without one.

## Invariants — violating any of these is wrong even if it works

Each is argued in the audit doc; this is the checklist form.

1. **One door, and the focus rule.** Every verb is addressed and goes through the
   daemon socket, the operator's keystrokes included. **Focus moves only when the
   operator acted, or when an agent's verb says the operator asked for it**: an agent
   verb without `--asked` lands in the background (a new tab, a drawer badge, a column
   to the right); with `--asked` it may bring something forward or focus it. "Only when
   asked" is a prompt rule in the `bench` skill, not a daemon check — benchd cannot know
   what the operator said (#320). There is **no typing lock**.
2. **No orchestrator concept in the app — ever.** No role, rank, team, or supervisor
   field in benchd, the wire contracts, the CLI, or the face. Hierarchy is prompts and
   skills, run *on* the bench. Attention items may be *addressed* to any tenant's queue;
   the daemon stores no notion of who routes to whom. Corollary: **an agent's role
   arrives in its spawn brief** — there is no relation in the daemon to look it up from,
   so a brief that assumes the recipient knows its place in a hierarchy is a bug in the
   brief. (Audit doc: "Orchestration … NOT part of the app".)
3. **Every agent is a full interactive TUI in a benchd pty.** Never `claude -p`, never
   `codex exec`. Attach from anywhere must be indistinguishable from sitting at the box.
   Resume after reboot is interactive `--resume` typed into a fresh pty.
4. **Yolo-mode semantics.** The operator runs wide-open postures; harness permission
   prompts effectively never fire. `blocked` is defined by bench signals
   (ended-on-a-question, stalled, idle-with-mail, errored, limited). Approvals exist
   only as voluntary agent-posted decision items.
5. **Cross-machine means files.** The record syncs as a folder over Tailscale. An agent
   on another machine shows the operator something by writing the artifact and a
   request file into the synced folder; the local benchd applies it in the background.
   Verbs stay host-local.
6. **No socket exposure and no peering until files prove not to be enough.** The
   daemon socket is never put on the network and benchd ⇄ benchd peering is not built
   while the synced folder does the job. The tailnet is the transport for the sync; no
   logins or tokens are added anywhere.
7. **Files are the record.** Mail, tasks, events, artifacts persist as files a plain
   `ls`/`cat` can read; sockets are transport, never the only copy.
8. **Agents own the bench's evolution.** They build it in this repo, test against an
   isolated `BENCH_SUITE` instance, and PR under the shared agent account. Restarting a
   live daemon under the operator is announced through a decision item first.
9. **Monorepo and gates.** `daemon/` is a cargo workspace with its own gate, run only
   when touched. The Swift gate keeps needing only the Swift toolchain. Rust is the
   single spelling of every wire type; the Swift side is generated, or a
   conformance-pinned duplicate under the repo's honest-duplicate rule (AGENTS.md).
10. **Keep helm's ported rules verbatim** where they survive: mailbox rules (notice
    carries path never body; `operator` reserved; retire never delete), spool semantics
    (claim-by-rename, two-phase results, status-plus-reason, the request-id newtype —
    landed in helm as #260, port it, don't reinvent it), close refusals
    (`holdsKeyboard` never overridable; busy = `getppid(fg) == getsid(fg)`), the select
    rule (#284: show a pane in a slot the operator is not in; three-valued keyboard
    state; no force override), pane naming (#313), the `AddressBook` owner-join rule
    (#247: session match first, pid only as fallback), the clipboard-destination rule
    (#297) at the terminal surface, unattended postures, prompt-out-of-argv, paste-then-submit
    launch lines.

## Working discipline, every milestone

- Additive before destructive: the new path runs in parallel until proven.
- Unwiring follows AGENTS.md's evidence rules: take the old path out, watch what fails,
  name the tests that proved parity, revert with `git checkout <base> -- <files>` when
  a step lies.
- Every wire contract gets a `SpoolWireConformanceTests`-shaped test: run the real
  binary as a subprocess, check both directions, every status case.
- Update AGENTS.md as verticals move — it documents the working tree, not the plan.
  (Note: the audit found existing AGENTS.md drift, listed in the audit doc Part I §
  "Weaknesses" item 5; fixing that is fair game any time.)
- **Do not assume current helm is fully working.** It is close, not done: there are
  rough edges, ~38 open issues, and behavior the operator wants different (the audit
  doc lists known defects). So wherever this roadmap says "prove parity," it means
  parity with the *intended* behavior — helm's documented rules and the operator's
  intent — not bug-for-bug parity with the running app. When old and new disagree,
  stop and decide which is right rather than copying the old; a migration step is a
  legitimate place to fix a rough edge, and fixing current helm in parallel stays fair
  game throughout.
- **Dogfooding is the arbiter.** The operator and the agents use the bench daily and
  tune it until it is just right *for them*; "proven in daily use" in this roadmap
  means that, not a test suite passing. Expect requirements to be corrected mid-flight
  by use — that is the process working, not the plan failing.

---

## M0 — Skeleton and isolation

**Landed 2026-08-18, PR #340** — with the spike verdicts in `daemon/spikes/`.

**Goal:** `daemon/` exists, runs, and is safe to develop against on the machine that
hosts the developers.

**Repo structure (decided — this is part of M0, not up for redesign):** Swift stays at
the root exactly where it is; `daemon/` is added beside it; nothing else moves. No
grand `apps/`-and-`crates/` reorganization — the strangler ethos applies to the
directory tree too, and the end state (a Swift face + a Rust daemon + sensors + skills)
already reads correctly from this layout.

```
helm/
├── AGENTS.md              # entry point; gains a short "daemon/" section
├── CONTEXT.md             # grows the bench vocabulary as terms land
├── docs/                  # this roadmap + the audit doc
├── Package.swift          # the face — the root Swift package never moves
├── Sources/ Tests/        # the face; slices shrink as verticals unwire
├── daemon/                # NEW — self-contained cargo workspace, own gate
│   ├── Cargo.toml         # [workspace]
│   ├── AGENTS.md          # gate command, conventions, invariants pointer
│   ├── test.sh            # cargo fmt --check, clippy, test, conformance
│   └── crates/
│       ├── benchd/        # the daemon
│       ├── bench/         # the CLI — the agent surface
│       └── bench-wire/    # every wire type, single spelling
├── hooks/  pi/            # taps stay in their runtime homes; contents thin, addresses never move
├── tools/                 # unwired at M3, then deleted
├── scripts/               # + wire-gen (bench-wire → generated Sources/BenchWire/)
├── Patches/               # stays: libghostty remains the renderer after M5
└── .claude/skills/        # + bench/ skill beside helm-canvas et al.
```

Rules carried by the structure: `daemon/` is the `pi/`-style carve-out (own gate, own
CI job on `daemon/**`, the Swift gate keeps needing only the Swift toolchain); there is
deliberately **no root `Cargo.toml`** (cargo at the repo root should fail loudly, not
half-work); generated Swift wire types land in `Sources/BenchWire/` marked
generated-never-edited, with the conformance-pinned duplicate as the per-type fallback;
the bench skill lives in `.claude/skills/bench/` with its snippets executed by its gate
against the real CLI.

- Cargo workspace `daemon/` with three crates: `benchd` (the daemon), `bench` (the CLI,
  which is also the future agent skill surface), `bench-wire` (every wire type, single
  spelling).
- Unix socket at a `BENCH_SUITE`-aware path; `BENCH_SUITE=<name>` isolates socket,
  record directory, and any state — port of helm's `HELM_DEFAULTS_SUITE` (#86)
  semantics: refuse loudly rather than fall back to the live instance.
- Event log (append-only JSONL) and the record layout under `~/.bench/` (suite-aware).
- Gate: `daemon/test.sh` (cargo test + CLI conformance harness), wired into CI as a
  separate job triggered by `daemon/` changes, per the `pi/`/`hooks/` pattern.
- `bench` CLI skeleton with `--suite`, exit-code discipline (0 ok / 2 no daemon /
  3 refused / 4 daemon failed — helm's spool codes, kept).

**Prove:** two instances (live + suite) run side by side with zero shared state.
**Unwire:** nothing.

> **Running order, operator-ruled 2026-09-25.** Milestone numbers below are kept as
> written; they no longer say what comes next. **Landed:** M0 (#340), M5a (#341),
> mail in benchd (#342, the core of M2), the shared browser (#350: #352, #363), and M4's
> daemon half — the bench document, its verbs and `events --follow` (#367, #373), and the session index, `bench sessions --all` (#392).
> **Next, in this order:**
>
> Tracking issue: **#362**; each step below has its own.
>
> 1. **M4** (#354) — the bench document, the verb seam and the surface model move to benchd.
>    The foundation: helm becomes a client of one document, and every later verb is
>    "mutate the document".
> 2. **M2 finish** (#358) — one mailroom: unwire helm's mail hooks and the pi watcher down to
>    sensors, so `bench mail` reaches every agent, the ones in helm panes included. Moved
>    ahead of M3 on 2026-09-25: benchd's mail reached only the sessions it spawned, so the
>    "who can I mail" directory (#396) listed most live agents without an address.
> 3. **M3** (#355) — `bench` is the whole agent surface: layout verbs with `--asked`, the see
>    verbs (`bench get state|pane|canvas|page|screenshot`, hidden panes included),
>    sharing (operator → agent: a page, a selection, a canvas or a screenshot, sent as
>    mail with a path), and one `move` verb behind key, drag and agent. The spool
>    scripts retire.
> 4. **Drawers, the keymap, the rules files and the `just` layer** (#356) — the Hyprland feel
>    (`bench-architecture.md`). The browser moves into a drawer.
> 5. **M1** (#357) — attention: taps, a queue drawer and a status-bar count. Mostly
>    projections of the event log by now.
> 6. **M5b** (#359) — every pane is a benchd session, shown through the attach relay in a
>    Ghostty surface; a VT engine in benchd (`libghostty-vt`, settled by spike 2026-09-25,
>    prebuilt and pinned to helm's Ghostty) gives `get screen` / `send` / `watch`. No custom
>    painter.
> 7. **M6** (#360) — sync: the record root as a synced folder, show-requests as files.
> 8. **M7** (#361) — the second machine, same entry condition as before.
>
> The earlier order (2026-08-18: M5a → M2 mail → M1 attention) is done as far as it
> went; attention moved later again because where it lives is now a drawer.

## M1 — Taps and the attention queue (purely additive)

Issue: #357.

**Goal:** the first new capability helm never had, proving daemon + socket + CLI + taps
end to end with zero risk to existing helm.

- Attention item model in `bench-wire`: kinds `blocked` (subtypes: `question`, `stall`,
  `idle-with-mail`, `error`, `limited`), `done`, `offer`, `decision`; optional
  addressee (any handle — generic addressing, see invariant 2); read/unread.
- Taps reporting to benchd over the socket:
  - Claude Code: hook scripts for `Notification`, `Stop` (with transcript-tail
    classification: done vs ended-on-a-question), `PreToolUse` (working). Wired by hand
    into `~/.claude/settings.json` like the existing mail hooks.
  - pi: `pi/extensions/bench` already forwards every state event through `bench hook pi`
    (#358).
  - codex: `notify` config handler + an output-classification fallback in benchd
    (herdr-style) for panes with no better signal.
- Verbs: `bench attn post|list|ack`, `bench watch <handle>` (blocks until a named
  tenant is genuinely blocked/done — the zero-token supervision primitive).
- Surface to the operator: a queue projection file (versioned JSON, atomic replace —
  `BenchSnapshot` conventions) that helm renders minimally: unread count in the status
  bar + a jump keybinding to the oldest `blocked`. Deeper UI comes with the face work.

**Prove:** a deliberately stalled agent and an agent ending on a question both surface
within seconds; `bench watch` wakes a watcher without a model turn; `limited` fires on
a rate-limit message.
**Unwire:** nothing.

## M2 — Mail authority moves to benchd

M2 finish: #358.

**Mail landed 2026-09-25, PR #342**: the mailroom (`bench-mail`), `bench mail
send|list|read`, and the wake reactor — benchd pastes the notice into an idle pty it
owns, uniformly across claude, codex and pi, with the loop cap as a per-recipient token
bucket in the courier. The Claude Code socket poke this section first planned was
**not built**: #320 measured it CONDITIONAL (a yolo session holds the poke behind a modal
nobody is watching), and pasting into a pty benchd owns needs no per-runtime transport.
What is left is **M2 finish**: the unwire list at the end of this section.

**M2 finish, 2026-09-26 (#441–#445): mostly done.** Each agent reports itself through
`bench hook <harness>` and gets its mail as hook context at its next tool call; an idle Claude
session is started through its inbox socket (the #320 route after all, with
`crossSessionInbound: "accept"` set once by the operator), and pi starts its own turn from its
`bench` extension. The paste is deleted: benchd never types into a pty. helm keeps no mailroom:
`hooks/`, `pi/extensions/helm-mail`, the conformance harness and the helm-mail skills are gone,
and helm asks benchd who is in a pane (`mail/who`). A codex benchd spawns runs its TUI against
its own app-server, and benchd starts its idle turns there; `just mail-ring` closed the
claude → codex → pi → claude ring through benchd, idle and busy (#358). **Left:** idle wake for
a codex the operator starts by hand, which embeds its app-server (M5b).

**Goal:** one owner for registry, liveness, and delivery; the flaky N-pairwise stitching
collapses into taps.

- benchd owns the mailbox root: claims, handles (port helm's widening + reserved
  `operator` rules), retire-never-delete, delivery notices (path, never body).
- Wake: benchd pastes the notice into the recipient's idle pty (paste, then Return
  separately), the same for claude, codex and pi, because it owns the pty. The file
  record stays canonical; deliver-before-turn remains the fallback for a pane benchd
  does not own. (Superseded: per-runtime transports, including the Claude Code
  session-socket poke and its `crossSessionInbound: "accept"` precondition. #320
  measured that a yolo session holds the poke behind a modal, so it was not built.)
- `bench mail send|list|read` verbs; hooks and pi extension thin to sensors +
  claim-reporting; benchd optionally registers bench tenants on the CC discovery path
  so `ListAgents` sees them.
- Loop caps bench-side on agent↔agent chains.

**Prove:** three-runtime mail matrix (each → each, idle and busy recipients) with wakes
observed. (The mailbox-conformance fixture set was not ported: with one mailroom there are no
copies left to compare, and #358 deleted it.)
**Unwire:** done in #358 — helm's hooks, its pi mail extension and both helm-mail skills are
deleted rather than thinned; `bench hook` and `pi/extensions/bench` are the sensors.

## M3 — The wire front moves

Issue: #355.

**Goal:** `bench` CLI is the whole agent-facing surface; the six spool scripts retire.
Runs after M4, so every verb here mutates the bench document benchd already owns.

- Layout verbs over the socket — `open|show|move|focus|close|name|spawn` — each landing
  in the background unless it carries `--asked` (invariant 1). One `move` verb serves
  the keyboard, drag and drop, and agents alike. These replace the six spool kinds
  (`spawn`, `close`, `capture`, `command`, `select` #284, `name` #313); helm's refusal
  rules for them (invariant 10) carry over where they still mean something under the
  focus rule.
- **See verbs**: `bench get state|pane|canvas|page|screenshot`, hidden panes included,
  so an agent can read what the operator is looking at without it being on screen.
- **Sharing**, operator → agent: send a page, a selection, a canvas or a screenshot as
  mail carrying a path.
- **Build/buy evaluation for the Claude spawn backend**: Claude Code ships a per-user
  supervisor daemon (`claude --bg`) with a pre-warmed worker and `claude attach <id>`
  adopting a session into any terminal. A benchd pane running the attach client keeps
  the full-TUI invariant while the session survives face/daemon restarts inside CC's own
  supervisor — and the operator measured dispatch at ~1k tokens for a `--bg` peer vs
  ~47k to stand up an in-process subagent. Caveat: `--bg` sessions do **not** survive
  machine reboot, so benchd's resume store stays regardless. Evaluate at this milestone
  by measurement; pi and codex remain benchd-pty either way.
- File drop-box under `~/.bench/` for socketless callers — claim-by-rename, same
  semantics, lower priority than the socket.
- Ship the `bench` SKILL.md (gated on a bench-set env var, herdr-style); retarget
  `SpoolWireConformanceTests`' assertions to the CLI.
- Unattended postures (`SpoolUnattendedPolicy`) enforced bench-side, unchanged.

**Prove:** CLI parity with all six scripts across every status case, via the
retargeted conformance suite; an agent verb without `--asked` never moves focus.
**Unwire:** `tools/helm-spool.swift`, `helm-close.swift`, `helm-capture.swift`,
`helm-command.swift`; then `tools/helm-spawn.swift` and `focus.swift` entirely (the GUI
dance is deleted, not ported).

## M4 — The bench document moves

Issue: #354.

**Goal:** benchd owns workbench state; helm becomes a renderer that still hosts ptys.
First in the running order, because every later verb is "mutate the document".

- Port the `Workbench` value to Rust: depth-2 columns/slots/panes, `normalize()`
  invariants, placement policies, visible/selected/focused. Mirror the Swift tests'
  assertions as Rust tests — `Workbench.swift` and `WorkbenchTests` are the spec.
- helm subscribes to document state over the socket and renders it; mutations go
  through bench verbs (operator keystrokes → helm → socket, same door as agents —
  invariant 1 becomes mechanically true).
- **The surface model**: a pane is a view of one surface named by a typed source
  (`term:<session>`, `file:<path>`, `browser`), and helm resolves each kind to a
  view through one `SurfaceKind` seam (`bench-architecture.md`). Drawers are **not** in M4
  (ruled 2026-09-25, D1 in the plan): nothing in M4 draws or changes one, so their shape is
  #356's to design, and the versioned document makes adding them later additive.
- helm keeps hosting ptys via its existing `SpoolSpawning`/`TerminalLaunching` protocol
  seams, now driven by benchd — the substitution those seams were built for.
- Canvas sources become **daemon-served**: the `helm-canvas://` scheme handler asks
  benchd for bytes instead of reading the filesystem (decision 2 in the audit doc;
  prepares cross-host artifacts). Canvas rules — latch, sidecar, annotation,
  `OperatorNote` — unchanged.
- Persistence moves from `UserDefaults` to benchd's record; one-time import of
  `helmWorkspaceContexts`.

**Prove:** the ported invariant tests; a full session (spawn, split, move, close,
restore) driven entirely through the socket; canvas renders an artifact it never read
from local disk.
**Unwire:** `WorkspacePersistence`'s workbench half. `BenchSnapshotModel` **stays**
(ruled 2026-09-25, D2), fed from the document: its terminal fields (pid, title, Claude's
status) come from ptys and registries only helm has until M5b, and removing it early loses
the stalled-at-a-prompt signal (#283). It goes at M5b, or at M3 if `bench get` replaces its
readers first.

**Plan (2026-09-25):** `~/.prp/helm-3ec376fc/plans/m4-bench-document-in-benchd.plan.md`,
published on #354. Four PRs: (1) the bench document ported to a pure Rust crate,
`bench-doc`, with the Swift tests mirrored; (2) layout verbs on the socket, `bench.json`
and `events --follow`; (3) helm as a client behind `HELM_BENCH=daemon`, with a one-time
import; (4) delete the Swift made dead. **Landed 2026-09-26:** client mode is the only mode;
the local bench, its defaults persistence and the switch are gone, and the import stays until
every machine has run it. D3 shipped earlier as `just benchd-install`. Also ruled: **D3** `make install` installs benchd
as a launchd agent in PR 4, and helm never spawns it; **D4** the restore-or-fresh question
(#85) stays in helm until M5b. Known gap until M5b: a spool spawn still switches the
operator to its workspace, because a pty helm hosts only starts once its pane is on
screen.

> **Split, operator-ruled 2026-08-18: M5a is pulled forward to land before mail; M5b
> stays here.** M5a **landed 2026-08-18, PR #341.** The pty spike proved daemon-owned
> ptys hosting full TUIs, which makes the cheap half cheap and the wake story clean:
>
> - **M5a — the daemon-session core, before mail.** benchd owns ptys for **new spawns
>   only**: `spawn`/`attach`/`close`/minimal `resume` verbs, a dtach-grade raw byte
>   relay for attach (ring-buffer replay, resize; no VT grid, no painter), viewed by
>   running `bench attach` inside an ordinary helm pane. Mail's wake then pastes into
>   a pty benchd owns — uniform across claude, codex and pi, no per-runtime transports.
>   Accepted interim costs, chosen knowingly: attach-hosted agents lose helm's pane
>   `agent` records and mark-routing identity until M4/M5b; canvas-push passthrough
>   through the relay is assumed and must be spiked before relying on it.
> - **M5b — the section below**, rewritten 2026-09-25 to the no-painter decision.

## M5 — Ptys move, per-pane

**Rewritten 2026-09-25 to the no-painter decision** (argued in `bench-architecture.md`,
"The terminal stack"). M5a landed; this section is M5b, issue #359, which also holds the
2026-09-25 version check.

**Goal:** every pane is a benchd session, the operator's own shells included; helm keeps
Ghostty's renderer; agents can read, write and follow any terminal; sessions survive
helm restarting.

- **helm shows benchd sessions through the attach relay inside a Ghostty surface.** That
  already works (M5a's `bench attach`). The operator keeps full Ghostty quality and one
  byte stream feeds both parsers. **No custom painter**: SwiftTerm is a visible step down
  and a Metal painter is months of work. **Keep the relay**: upstream Ghostty has no
  backend without a pty (PR #14277 is tmux-specific, and 1.4 targets scripting and tmux
  control mode). If one ever ships, the inner relay pty goes away and nothing else
  changes.
- **Replace `portable-pty`** (nothing published in 19 months; its Windows support is
  dead weight) with `rustix` `openpty` and our own spawn. Near-term, and it can land
  before the VT spike.
- **A VT engine per session in benchd: `libghostty-vt`**, settled by two spikes on
  2026-09-25 (verdicts on #359; reports `spike-vt-engine-choice.md` and
  `spike-prebuilt-vt-archive.md` in `~/.prp/helm-3ec376fc/spikes/`).
  - **Fidelity:** on recorded claude, codex, pi and fish sessions it matched helm's own
    Ghostty engine (text and cursor) at every checkpoint. `alacritty_terminal` matched
    outside resizes, but diverged in 4 of 8 resize cases and on emoji width under mode
    2027. It stays the fallback.
  - **Threads:** one VT thread per session, fed by the pty drain thread over a bounded
    channel, because `Terminal` is never `Send` (upstream won't-fix). Snapshot p99 was under
    0.52 ms at 50 sessions. Reads get a lane separate from output. Memory is 11 to 12 MB per
    session, against 33 MB for alacritty.
  - **Build, with no zig in the gate:** a stripped, hash-pinned `libghostty-vt.a` per
    platform (macOS arm64 2.0 MB, x86_64 Linux 2.7 MB), built once per Ghostty bump by a
    script that needs zig (0.15.x at the spike). It is linked through a Cargo `links` override, so the
    crate's `build.rs` never runs. A 15-line `build.rs` in a crate of ours passes the
    absolute path, and the crate is not forked. Replayed output was byte-identical to the
    zig build.
  - **Pin to helm's Ghostty**, `ghosttyCommit` in `Packages/GhosttyTerminal/Package.swift`
    (`35e1a016` when the spike ran; `6301810a` since 2026-09-26), not the crate's own
    `a887df42`. Without the override, the crate silently fetches its own pin. Build it from
    the checkout `scripts/bump-ghostty.sh` makes; `docs/VENDORED.md` ("Ghostty") keeps the
    coupling. Ghostty now needs zig 0.16, where the spike used 0.15.2.
  - **Every Ghostty bump** moves both pins together, and must check the crate's checked-in
    bindings against the new header. A changed struct layout compiles and misbehaves.
  - **The archives live in the repo** (decided 2026-09-25, the operator delegated): plain
    git, beside their `SHA256SUMS`, about 1.5 MB compressed per Ghostty bump. The daemon
    gate and CI stay Rust-only and need no network. A release asset fetched by script was
    the alternative: it keeps binaries out of git, at the cost of a network fetch on first
    build and one more script to maintain. A Ghostty bump is agent work, not the operator's:
    one script rebuilds both archives with zig, then the agent commits them with their
    new sums and checks the crate's bindings against the new header.
- **Design rules from the spikes, whichever engine:**
  1. Mid synchronized update (mode 2026), serve the last complete frame. Read naively,
     22 to 34% of checkpoints in real agent output were torn.
  2. Resize the engine in lockstep with the pty.
  3. The scrollback limit is in bytes (16 MiB, matching helm). The C header's "lines" is
     wrong.
  4. Decide who answers terminal queries. With no viewer attached only benchd can, and
     all three agents ask at startup. With one attached, Ghostty answers too, and replies
     would be doubled.
- **`bench get screen`, `bench send`, `bench watch --screen`** on any pane. zellij's
  `action subscribe` (pane content streamed as JSON) is the reference design for
  `watch`.
- Hostile-output policy (OSC 52 clipboard, helm #297) stays at the terminal surface.
- Restore-on-restart is benchd's. Reboot flow: benchd relaunches each session's pty and
  types the interactive `--resume` line (paste, then Return; helm's launch-line rules).

**Prove:** kill helm mid-session, relaunch, every pane is where it was with nothing lost;
reboot, sessions resume; an agent reads the operator's shell with `bench get screen` and
it matches what is on screen.
**Unwire:** the pty-ownership half of `TerminalManager`/`TerminalSession`, the
restore-offer machinery (`awaitingRestore`/`resumable` — mostly dissolved), and the OSC
push path in `CanvasPush` (replaced by `bench open`). libghostty stays as the renderer.

## M6 — Sync (still one machine)

Issue: #360. **Rewritten 2026-09-25**: cross-machine means files (invariants 5 and 6). This replaces
the earlier "Reach" plan, which put the daemon socket on the tailnet.

**Goal:** the record root is a folder that syncs over Tailscale, and showing something
across machines is a file, not a connection.

- The record root (mail, artifacts, notes, state, config) as a synced folder over the
  tailnet.
- **Show-requests as files**: an agent on another machine writes the artifact and a
  request file into the synced folder; the local benchd picks it up and applies it in
  the background, exactly as a local agent verb without `--asked` would land.
- No socket exposure, no remote attach, no peering protocol. Phone and laptop reach come
  later, if wanted, and only once files have proved not to be enough.

**Prove:** a request file written into the synced folder from another device lands as a
background tab on the Mac without moving focus.
**Unwire:** nothing.

## M7 — The forge

Issue: #361.

**Goal:** the agents' own machine, sharing the record with the Mac through M6's synced
folder.

**Entry condition: M0–M6 complete and proven in daily use on the Mac.** This milestone
starts when the second machine is actually purchased and wanted — not before, and never
as a way to test earlier milestones.

- Linux support proven for `benchd` + `bench` + taps (should be near-free; verify).
- The same benchd on the agents' box, sharing the record through M6's synced folder:
  mail and show-requests cross machines as files. No benchd ⇄ benchd peering and no
  cross-host verbs (invariants 5 and 6); add a protocol only if files prove not to be
  enough.
- Per-host policy files: operator refusals on the Mac; wide posture and wider allowlist
  on the forge.
- Setup on the forge: the shared agent GitHub account and shared keys (decision 4);
  backup cron for `~/.bench` and the artifact stores (the one messiness exception).
- Phone push for attention items (ntfy or similar on the tailnet).

**Prove:** sleep the Mac for an hour mid-fleet; wake it; nothing on the forge noticed.
An artifact shown from the forge lands on the Mac bench once the folder syncs.
**Unwire:** nothing — this milestone only adds a machine.

## Alongside the milestones — the shared browser (#350)

Landed, not a numbered milestone (#352, #363). benchd **supervises one browser** (a helper,
like a session: persistent profile under the bench root, a CDP port, its endpoint published
in `<root>/browser/endpoint.json` for agents to read), and helm has a **browser pane**, so
the operator and agents share one logged-in browser. Agents drive it with their own
Playwright (`playwright-cli attach --cdp=…`); the bench is a supervisor and a viewer,
**never a browser driver**. The Chrome question is settled: **real Google Chrome** by
default, so the Claude in Chrome and Codex extensions can run in it, with Chrome for
Testing as the fallback (`bench browser setup` opens the profile headed to install them).
The pane becomes the `browser` surface kind with M4 (no tab field, as in #353) and moves
into a drawer once drawers exist.

---

## Still open (settle when reached)

- **Queue triage / morning digest** (M1+): since-you-left counts grouped by project and
  addressee — a pure projection of the event log. Build early; the first busy morning
  will demand it.
- **benchd restart vs. pty survival**: accepted as a resume-storm (decision 3). Revisit
  the per-session pty-holder shim only if upgrade frequency hurts — likely once agents
  are actively developing the bench itself; until then `BENCH_SUITE` covers it.
- **Browser gaps** (#350, not built): IME inline preview (text commits, the composition
  is not drawn), a file-chooser or download UI, and a start button in the pane. Also
  unproven until the operator runs it: extensions working while the browser runs headless.
- **Canvas notes** (#251 follow-ups, not built): a `HelmCommand` to open the notes drawer
  (needs its own `SpoolCommandPolicy` ruling), and a "no sidecar" notice on URL canvases.
- **Rich reading of a session's history** ("what happened overnight"): scrollback +
  transcripts + asking the agent. Deliberately not designed yet; do not build a chat
  renderer (audit doc, "What not to build").

## Naming note

`bench`/`benchd` — blessed by the operator 2026-08-11. The name is settled and M0 bakes
it into crate names, the socket path, `BENCH_SUITE`, `~/.bench/` and the CLI; do not
reopen it.

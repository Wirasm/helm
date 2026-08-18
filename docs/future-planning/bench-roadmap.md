# bench roadmap — the strangler migration, milestone by milestone

**Read this cold.** This document assumes no prior context. The full argument — audit,
landscape research, architecture, decisions and their rationale — is
`docs/future-planning/workbench-audit-2026-08.md` (same directory); read it before starting any
milestone. This file is the actionable sequence: what to build, in what order, what
proves each step, and what gets unwired when.

**The one-paragraph vision.** helm evolves into "the bench": a headless Rust daemon
(`benchd`) owns everything that must survive — ptys, VT state, the workbench document,
mail, tasks, an attention queue, the event log — and the SwiftUI app becomes a thin
face that renders daemon state. The operator and the agents are equal owners: every
verb exists in an addressed, non-seizing form and both parties go through the same
socket. Later, a second machine (the forge) runs the same daemon with a wider policy so
agents get their own always-on box; the Mac attaches. Migration is strangler-style
inside this repo: one vertical at a time, old code unwired only when the new is proven.

**Everything is built and proven on one machine — the operator's Mac — first.** The
second machine is not added until M0–M6 are done and living well in daily use; do not
stand up a forge, a VM, or a remote peer "to test peering" before then. The design is
machine-count invariant on purpose (topology is config), so nothing in M0–M6 needs a
second machine to be built correctly — M6 (Reach) is the operator's devices attaching
to the one machine over the tailnet, not a second machine — and `BENCH_SUITE` gives
every isolation the early milestones need without one.

## Invariants — violating any of these is wrong even if it works

Each is argued in the audit doc; this is the checklist form.

1. **Equal owners, one door.** Every verb addressed, symmetric, through the daemon
   socket. Only two things stay the operator's: attention (focus, the keyboard) and
   approval. Nothing an agent sends may move the operator's focus.
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
5. **Verbs are host-local.** Cross-host traffic is petition-only: mail, attention,
   tasks. An agent that should operate a machine's bench runs on that machine.
6. **The tailnet is the entire auth story.** Device identity on the Tailscale network;
   no logins, no tokens, no manual auth anywhere in the estate.
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
    (#297) in the painter, unattended postures, prompt-out-of-argv, paste-then-submit
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
├── Patches/               # dies at M5
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

> **Reordering, operator-ruled 2026-08-18: mail lands before the attention queue.**
> *"Attention can go later because we don't know where we want attention right now."*
> The tap dependency that originally ordered them is softened by measurement — the
> spike verdicts in `daemon/spikes/` proved the pty-paste wake on all three runtimes
> with a plain pty-quiet idle gate, so mail's wake path does not wait for taps.
> Milestone numbers below are left as written; start with M2, then return here.

## M1 — Taps and the attention queue (purely additive)

**Goal:** the first new capability helm never had, proving daemon + socket + CLI + taps
end to end with zero risk to existing helm.

- Attention item model in `bench-wire`: kinds `blocked` (subtypes: `question`, `stall`,
  `idle-with-mail`, `error`, `limited`), `done`, `offer`, `decision`; optional
  addressee (any handle — generic addressing, see invariant 2); read/unread.
- Taps reporting to benchd over the socket:
  - Claude Code: hook scripts for `Notification`, `Stop` (with transcript-tail
    classification: done vs ended-on-a-question), `PreToolUse` (working). Wired by hand
    into `~/.claude/settings.json` like the existing mail hooks.
  - pi: extend `pi/extensions/helm-mail` (or a sibling extension) to forward state
    events.
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

**Goal:** one owner for registry, liveness, and delivery; the flaky N-pairwise stitching
collapses into taps.

- benchd owns the mailbox root: claims, handles (port helm's widening + reserved
  `operator` rules), retire-never-delete, delivery notices (path, never body).
- Wake transports, per recipient runtime: Claude Code — poke the session's
  cross-session messaging socket (`/tmp/cc-socks/<pid>.sock`, arrives as a new user
  turn); pi — in-process wake via the extension; any TUI at an idle prompt — benchd
  pastes the notice into the composer and submits (guarded by the tap's idle check;
  paste, then Return separately). Deliver-before-turn remains the no-transport
  fallback. Note M2 is *small*: the socket post is the entire CC delivery mechanism —
  the file record stays canonical and survives any socket incident untouched.
- **Named precondition (verified 2026-08-11, not a footnote): every spawned Claude Code
  agent must carry `crossSessionInbound: "accept"` in its settings.** The inbound
  default derives from permission modes, and a bypass-permissions (yolo) session
  **silently holds** any message whose sender doesn't identify as also bypassing — held
  mail is dropped after the dialog expiry (default 5 min) in unattended contexts. benchd
  never qualifies for the unverified-sender exception because that exception is for the
  session's own *children* and benchd is the parent. Without this setting, every wake in
  this design silently fails; the M2 prove-matrix must include a yolo→yolo wake through
  benchd.
- `bench mail send|list|read` verbs; hooks and pi extension thin to sensors +
  claim-reporting; benchd optionally registers bench tenants on the CC discovery path
  so `ListAgents` sees them.
- Loop caps bench-side on agent↔agent chains.

**Prove:** three-runtime mail matrix (each → each, idle and busy recipients) with wakes
observed; the mailbox-conformance fixture set (`hooks/mailbox-conformance.mjs`) ported
and green against benchd.
**Unwire:** delivery/reap logic in `hooks/helm-mail.mjs` and the pi watcher (sensor
halves stay); the Arm-a-watch instructions in the mail skills.

## M3 — The wire front moves

**Goal:** `bench` CLI is the one agent-facing surface; the four spool scripts retire.

- `bench spawn|close|select|name|capture|cmd` implemented over the socket, with benchd
  *forwarding* to helm's existing spool during transition (helm unchanged; the spool now
  has six kinds — `select` #284 and `name` #313 joined after the audit).
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

**Prove:** CLI parity with all four scripts across every status case, via the
retargeted conformance suite.
**Unwire:** `tools/helm-spool.swift`, `helm-close.swift`, `helm-capture.swift`,
`helm-command.swift`; then `tools/helm-spawn.swift` and `focus.swift` entirely (the GUI
dance is deleted, not ported).

## M4 — The bench document moves

**Goal:** benchd owns workbench state; helm becomes a renderer that still hosts ptys.

- Port the `Workbench` value to Rust: depth-2 columns/slots/panes, `normalize()`
  invariants, placement policies, visible/selected/focused. Mirror the Swift tests'
  assertions as Rust tests — `Workbench.swift` and `WorkbenchTests` are the spec.
- helm subscribes to document state over the socket and renders it; mutations go
  through bench verbs (operator keystrokes → helm → socket, same door as agents —
  invariant 1 becomes mechanically true).
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
**Unwire:** `WorkspacePersistence`'s workbench half, `BenchSnapshotModel` (the snapshot
becomes a benchd projection of the event stream, same file shape for readers).

## M5 — Ptys move, per-pane

**Goal:** benchd owns the processes; the face becomes a painter; sessions survive the
app and, eventually, the machine's lid.

- pty + VT state in benchd (`portable-pty` + `wezterm-term`, or libghostty-vt — a
  swappable internal; pick whichever proves out first).
- Attach protocol in `bench-wire`: grid snapshot + diffs down, keys/resize up.
- A new **painter pane kind** in helm renders daemon grids (Metal/CoreText). Old
  libghostty panes and painter panes coexist on one bench; migrate pane by pane.
- Hostile-output policy lands here once, in the painter (OSC 52 clipboard — helm #297).
- `bench attach` TUI client (also the ssh/phone path).
- Reboot flow: benchd relaunches each session's pty and types the interactive
  `--resume` line (paste, then Return; helm's launch-line rules).

**Prove:** kill the face mid-session, reattach, nothing lost; reboot, sessions resume;
a painter pane and a libghostty pane side by side are indistinguishable in daily use.
**Unwire:** libghostty hosting, the vendored multi-surface wakeup patch and
`patch-libghostty.sh`, the pty-ownership half of `TerminalManager`/`TerminalSession`,
the restore-offer machinery (`awaitingRestore`/`resumable` — mostly dissolved), and
every display-bound workaround (OSC push path in `CanvasPush` → replaced by
`bench open`).

## M6 — Reach (still one machine)

**Goal:** "I'm anywhere, the machine's at home, I open the bench and work." This is the
posture the whole design serves, it needs no forge and no second dev machine — only a
daemon that isn't in the app — and it deliberately gets its own milestone rather than
hiding inside the forge's peering.

- Expose the daemon's socket on the tailnet (tsnet listener or Tailscale serve); device
  identity is the entire auth story (invariant 6).
- `bench attach` and the queue/mail/attn verbs from the laptop and phone (ssh TUI; push
  via ntfy on the tailnet); artifacts render remotely via daemon-served canvas bytes
  (M4).
- **Partial reach can land much earlier and should**: from M1 the attention queue and
  mail are socket verbs, so exposing them costs one tailnet listener — read the queue
  and answer a decision item from the phone before terminals are even daemon-held. Full
  terminal reach needs M5's attach protocol.

**Prove:** from off-LAN — read the queue, answer a decision item, attach to a live
session, push an artifact and see it rendered.
**Unwire:** nothing.

## M7 — The forge

**Goal:** the agents' own machine; the Mac becomes an attach point.

**Entry condition: M0–M6 complete and proven in daily use on the Mac.** This milestone
starts when the second machine is actually purchased and wanted — not before, and never
as a way to test earlier milestones.

- Linux support proven for `benchd` + `bench` + taps (should be near-free; verify).
- Peering: benchd ⇄ benchd over the tailnet — mail delivery, task sync, wake relay,
  attach relay, artifact bytes. Host-qualified handles (`name@host`). Petition-only:
  no cross-host bench verbs (invariant 5).
- Per-host policy files: operator refusals on the Mac; wide posture and wider allowlist
  on the forge.
- Setup on the forge: the shared agent GitHub account and shared keys (decision 4);
  backup cron for `~/.bench` and the artifact stores (the one messiness exception).
- Phone push for attention items (ntfy or similar on the tailnet).

**Prove:** sleep the Mac for an hour mid-fleet; wake it; nothing on the forge noticed.
An artifact pushed on the forge renders in the Mac face. A decision item posted on the
forge reaches the phone.
**Unwire:** nothing — this milestone only adds a machine.

---

## Still open (settle when reached)

- **Queue triage / morning digest** (M1+): since-you-left counts grouped by project and
  addressee — a pure projection of the event log. Build early; the first busy morning
  will demand it.
- **benchd restart vs. pty survival**: accepted as a resume-storm (decision 3). Revisit
  the per-session pty-holder shim only if upgrade frequency hurts — likely once agents
  are actively developing the bench itself; until then `BENCH_SUITE` covers it.
- **Rich reading of a session's history** ("what happened overnight"): scrollback +
  transcripts + asking the agent. Deliberately not designed yet; do not build a chat
  renderer (audit doc, "What not to build").

## Naming note

`bench`/`benchd` — blessed by the operator 2026-08-11. The name is settled and M0 bakes
it into crate names, the socket path, `BENCH_SUITE`, `~/.bench/` and the CLI; do not
reopen it.

# Workbench architecture audit — helm today, and a greenfield "equal owners" design

2026-08-09. Three inputs: a full audit of this repo (source, tests, tools, skills, hooks,
open issues), a survey of the 2026 agent-workbench field verified against primary sources,
and a deep pass on the four named closest relatives — cmux, Orca, herdr, FirstMate. Part I
is what helm is and where it stands. Part II is the landscape facts that change the design
space. Part III answers the design question: *a personal workbench for the operator and
agents as equal owners of the bench* — no language or architecture restrictions, composing
custom tools by use case, on a Mac.

---

## Part I — Audit of helm

### What it is

~55,600 lines of Swift across 270 files: `Sources/Helm` 22,341 LOC in 17 vertical feature
slices, `Sources/HelmWire` 2,300 LOC of wire types, 28,786 LOC of tests (1,320 test
functions — better than 1:1 test:source), and 2,143 LOC of standalone `tools/*.swift`
scripts that deliberately compile outside the package. 42% of source lines are comments,
and they are not decoration — they carry measurements, issue citations and recorded wrong
first readings. The codebase is closer to an ADR log with an app attached than the reverse.

The architecture is consistent to an unusual degree:

- **Values at seams, live objects at the edge.** `Workbench`, `CanvasSource`,
  `SpoolRequest`, `BenchSnapshot` are `Codable` values; `WorkbenchModel` is the single
  resolver. Layout, placement and focus rules are unit-testable with no window, pty or
  webview.
- **Newtypes as mechanism** — `StandardizedPath`, `WorkspacePath`, `TerminalID`, `Handle`,
  `CanvasStateBody`, `OperatorNote` each make the un-validated value unconstructable. The
  counter-rule (permissive decode, strict judgement — `CloseRequest.terminal` stays a raw
  `String`) is argued in headers.
- **Pure policy types, exhaustively switched** — `SpoolCommandPolicy` is total over all 20
  `HelmCommandName` cases, so a new command cannot ship without a verdict; `movePane` and
  `newNote` both arrived refused because the compiler asked.
- **Systematic operator/agent verb pairing** — `insert`/`offer`,
  `splitRight(with:)`/`splitRight(offering:)`: "appear, don't seize" as paired methods, not
  a flag.
- **Honest duplicates with named detectors.** Four wire formats are written twice across
  runtime boundaries (spool JSON, mailbox format, `data-helm-surface`, the surface-failure
  recipe), and each has a conformance test whose only job is noticing drift —
  `SpoolWireConformanceTests` runs the real scripts as subprocesses and checks every
  `SpoolResult.Status` case both directions.

### The agent-facing surface

Everything splits on one axis: what an agent can do **headless** (screen locked, over ssh,
no TCC grants) versus what needs the display.

Headless — the real surface:

| Capability | Mechanism | Guard |
|---|---|---|
| Spawn a peer agent | spool `spawn` → two-phase result with `terminalId`, `pid`, `sessionId`, `handle` | `allowedCommands = {claude, pi, codex}`; unattended posture per agent |
| Close a pane | spool `close`, one uuid namespace for terminal and canvas | live-process refusal (`--force` overrides); operator's-pane refusal (nothing overrides) |
| Rearrange the bench | spool `command` — 4 of 20 commands allowed | the other 16 refused, each naming why and the route instead |
| See the window | spool `capture` — helm draws itself, no TCC | `terminalContent` computed per capture, never assumed |
| Read the bench | `~/.helm/bench/snapshot.json`, versioned, atomic | `awaitingRestore` / `isOffered` readable but deliberately unanswerable |
| Message a peer | file mailbox, claim/deliver via hooks (CC) and a live extension (pi) | `operator` reserved; retire-never-delete; notice carries path, never body |
| Hear from a page | canvas state latch `<artifact>.state.json` | object-only, 64 KB, latest-wins, next-turn-not-interrupt |
| Hear from the operator | canvas marks routed as mail to the pushing agent | wakes an idle agent — human intent carries |

Display-bound (the ceiling the spool exists to escape): `push.sh` (needs a writable pty in
the ancestry), `helm-spawn` (unlocked screen + Accessibility), `winshot` (Screen Recording
grant). Each refuses loudly rather than typing into nothing — every one exists because a
previous version reported success silently.

### Where helm stands in the 2026 field

The four named relatives, and what each proves:

- **cmux** (manaflow-ai, ~26k stars) is convergent evolution on helm's exact stack: native
  Swift + libghostty (not a fork), a Unix-socket/CLI command surface, OSC-based
  notifications, session resume via hooks. Its differentiators are attention routing (blue
  ring on the pane that needs input, unread badges, ⌘⇧U jumps to most recent unread) and an
  embedded browser with an agent automation socket. Raw terminal only, by conviction.
- **herdr** (~26k stars) is the daemon-first answer: a Rust server owns the PTYs, a TUI
  client attaches. Close the lid, drop the network, restart the machine — the agents keep
  running and the layout comes back *with sessions resumed*. It classifies every pane into
  working / blocked / done / idle by process and output sniffing, ships a SKILL.md that
  teaches agents its own surface, and gates it on `HERDR_ENV=1`.
- **Orca** (stablyai, ~40k stars, Electron) is the maximalist: worktree-per-agent fleets,
  a first-class review surface (line comments on diffs sent back as agent input), a typed
  orchestrator (`dispatch` / `worker_done` / `escalation` / `decision_gate` with human
  approval gates), mobile companion apps.
- **FirstMate** is not an app — an "agent distro" layered on the others, with the one idea
  worth stealing outright: **zero-token supervision** — a bash watcher sleeps on the fleet
  and wakes the lead agent only when something actually needs it, plus a turn-end backstop
  against an agent quietly stopping mid-task.

Cross-cutting: none of the four renders rich chat; attention routing is the contested
feature and helm currently has the least of it; only helm has a document surface (canvas,
annotations, notes, state latch) — Orca's diff viewer is the nearest thing. And the wider
field's casualties (Terragon dead, Crystal deprecated, Vibe Kanban sunsetting, Warp
open-sourced and pivoted to cloud) all sat in the "human supervises a fleet of hidden
workers" quadrant, squeezed between free first-party tooling and the editors. **Nobody
shipped helm's model** — human and agents as co-tenants of one visible bench.

### Weaknesses, tied to the tracker

1. **The GUI process owns everything.** helm dies → every hosted agent dies (accepted in
   direction.md, but #235 shows the cost: a restart loses every session). The spool "works
   headless" except that spawning ultimately needs an active display for the surface
   (#253 — a sleeping screen fails every spawn). This is the single structural weakness,
   and herdr proves the alternative works.
2. **Attention routing is thin.** Bells, `isVisible`, desktop notifications — but no
   working/blocked/done/idle classification, no unread queue, no "jump to what needs me."
   A spool-spawned agent stalled 6.5h at a prompt the unattended posture didn't cover
   (#283); nothing surfaced it.
3. **From-disk chat view is structurally behind.** Measured in direction.md: transcript
   grain is one content block per record, a median 8.8s behind, and an agent blocked on a
   question writes *nothing* — the moment most demanding attention is exactly when the file
   is silent.
4. **Known debt, honestly tracked**: spool `id` still a bare `String` gated at one of six
   sites (#260, path traversal reachable via `answerAbandoned`); mailbox not isolated
   under `HELM_DEFAULTS_SUITE` (#285); `push.sh` exits 0 from outside a helm pane having
   written its OSC into some other terminal (#282); pre-turn mail delivery leaves no trace
   in either transcript (#136); OSC 52 clipboard overwrite open (#297).
5. **Doc drift found by this audit** (each worth a small PR):
   - AGENTS.md says both mail runtimes are "capped at 3 consecutive wakes." False — only
     pi has `WAKE_CAP = 3`; `hooks/helm-mail.mjs` states in a dedicated block that there
     is deliberately no cap on the Claude Code side (pre-turn delivery spends nothing).
   - `howToReply` in `hooks/helm-mail.mjs` still says `/helm-mail-cc` is broken pending
     #237; #237 has landed and the skill is fixed.
   - The canvas state latch, `helmCanvasUpdate`, the operator→agent mail route,
     `AddressBook`/#247, `HELM_MAIL_OFF`/`HELM_MAIL_DIR`, `helm-spool --no-wait`, and both
     `.claude/agents/` subagents are absent from AGENTS.md; the "Agent skills" section
     lists 3 of the 5 helm-local skills' *gates* but not the skills.
   - `Archon/` + `Worktrees/` (~3,300 LOC) and `Chat/` (1,676 LOC) — the third-largest
     area of the app — are undescribed in AGENTS.md's architecture section.
   - Naming collision: `Sources/Helm/Board/` (agent presence + snapshot) vs the drawable
     board (`.claude/skills/helm-board/`). CONTEXT.md defines neither sense.
   - The local gate and the CI gate are not the same gate (CI skips the two
     surface-needing suites); only `gate.yml` comments say so.
   - AGENTS.md's premise that an idle Claude Code session cannot be woken from outside
     ("the notice instead tells the agent to arm its own watch; being notified is the
     wake") is outdated as of Claude Code v2.1.224: cross-session messaging delivers into
     an idle session as a new user turn. The whole Arm dance in `helm-mail-cc` is now the
     long way around for CC→CC mail.

---

## Part II — Landscape facts that change the design space (verified Aug 2026)

1. **ACP (Agent Client Protocol) won the editor↔agent seam.** JSON-RPC over stdio, v1:
   session lifecycle (`new`/`load`/`resume`), streaming `session/update` (message chunks,
   tool calls, plans, mode changes), **`session/request_permission` routed to the host**,
   host-provided FS and **host-owned terminals**, MCP pass-through. ~35 native
   implementations (Gemini CLI, Goose, Copilot, OpenCode, Cline, JetBrains…) and adapters
   for **Claude Code** (`claude-code-acp`, on the Agent SDK), **codex**, and **pi**
   (`pi-acp`). A registry (Jan 2026) lets any client install any agent. This is exactly
   the structured stream helm's chat face lacked: the pending permission question arrives
   as an *event*, not as silence on disk.
2. **Claude Code grew first-party versions of helm's primitives.** Agent teams
   (experimental): per-agent JSON inbox files at `~/.claude/teams/<team>/inboxes/`,
   file-locked task claiming, plan-approval gates — and its split-pane display supports
   tmux/iTerm2 but **explicitly not Ghostty**, so a native multi-pane host is a gap
   Anthropic left open. Cross-session messaging (v2.1.224+, on by default):
   `ListAgents`/`SendMessage` over a per-session Unix socket
   (`CLAUDE_CODE_MESSAGING_SOCKET`, sockets under `/tmp/cc-socks/<pid>.sock`) with
   disk-based discovery, inbound policies, loop throttling — and, decisively, **a message
   delivered to an idle session's socket arrives as a new user turn and wakes it**. The
   founding premise of helm's Claude Code mailbox half — "nothing outside a Claude Code
   session can start a turn, so the notice tells the agent to arm its own watch" — is no
   longer true, and the operator already exploits this (the `peer-sessions` skill,
   github.com/ray-amjad/peer-sessions, is a worked example: name→socket resolution,
   reply-address-in-the-brief because the peer cannot discover the sender, spawn/teardown
   scripts — placed, as it happens, via cmux). Agent view: `claude --bg`, auto-worktrees
   under `.claude/worktrees/`,
   autonomous draft PRs. The Agent SDK exposes the whole loop programmatically with
   resume/fork and permission callbacks.
3. **libghostty was extracted.** Ghostty 1.3.0 (March 2026): libghostty is now a
   standalone full-featured Zig module with its own release cycle — but no tagged release
   yet and the C API is still WIP. **libghostty-vt** (the zero-dependency VT parser/state
   machine, C API) is real and usable. Terminal state can now live in a process that does
   not render.
4. **MCP went stateless** (2026-07-28 revision): handshake and protocol sessions removed,
   sampling/roots deprecated, durable "tasks" as an extension. Don't build coordination on
   the deprecated parts; elicitation survives via multi-round-trip requests.
5. **The market said something.** Fleet-supervision startups died; pty-first muxes (cmux,
   herdr) and ACP hosts (Zed, JetBrains) thrived; the co-ownership quadrant is empty.

---

## Part III — Greenfield: "me and agents as equal owners of the bench"

### What "equal owners" actually changes

helm's constitution is *appear, don't seize*: agents are well-treated guests — 4 of 20
bench verbs, no addresses, no focus. Equal ownership is a different constitution, and the
audit shows the path: **every one of the 16 refused commands is refused for lacking an
address**. Equality is not "agents may take focus" — it is "every verb the operator has
exists in an addressed, non-seizing form, and both parties go through the same door."

The honest asymmetries that remain are not ownership asymmetries:

- **Attention is the operator's.** The keyboard, the focused pane, which workspace is on
  screen — never taken, only requested. This is a scarcity fact, not a rank fact: the
  operator is the only participant who cannot be woken by a file write.
- **Approval is the operator's.** Merges, deletions of unmerged work, spend. Same reason.
- **Everything else — arrangement, panes, artifacts, spawning, closing, moving,
  annotating — is symmetric.** An agent may reorganize the bench, open a canvas beside
  its terminal, close its own pane, spawn and supervise a peer, and *petition* for
  attention. The operator may do all of that to agents' panes too — and the same refusal
  protects an agent's busy pane from a careless close that protects the operator's.

### The architecture: three parts, one surface

**1. `benchd` — a headless daemon that owns everything that must survive.**

The single biggest lesson from the audit and the field (helm #235/#253 on one side, herdr
on the other): the process that owns the ptys must not be the process that draws. benchd
owns:

- the ptys and their VT state — **libghostty-vt** embedded in the daemon, so scrollback
  and screen state live server-side and any client renders a grid snapshot + diffs;
- the bench document (workspaces → columns → slots → panes, helm's depth-2 model, ported
  as-is — it is correct);
- the spool successor: a **Unix socket API and a CLI that are the same surface** (the
  cmux/herdr convergence), with file-based request/result kept as the degraded transport
  for callers that can't hold a socket;
- the mailbox, the task queue, the event log, the snapshot projection.

Consequences bought outright: the app restarting costs nothing (reattach); the machine
rebooting costs a `--resume` per agent, driven by the daemon from stored session ids
(cmux's hook trick, helm's `resumable` field, done automatically); ssh and a future phone
client are the same attach path; a spawn needs no display *actually*, not aspirationally.

Language: the daemon in **Rust or Zig** (single static binary, no toolchain state — the
same property helm's spool scripts fight for; Zig gets libghostty-vt natively, Rust has
mature everything else and is the safer bet), the Mac client in **Swift/SwiftUI** and
deliberately thin. If starting from helm instead of from zero, Swift-for-both with the
daemon as an SPM executable is defensible — the split matters far more than the language.

**2. The Mac app — a renderer and an attention instrument, nothing else.**

SwiftUI shell over daemon state: renders terminal grids (Metal, from libghostty-vt state —
this is the one hard rendering problem; the fallback is embedding full libghostty
per-surface in the app and treating pty ownership transfer as the daemon's job, which is
cmux's shape), canvases (WKWebView, ported from helm — `CanvasSchemeHandler`, the bridge,
the latch, the annotation model are all portable values and files), and the attention
system (below). Everything the app knows it learned from the daemon's event stream, so the
bench snapshot file stops being a projection helm writes and becomes *the same API the app
itself uses* — one source of truth, no drift class.

**3. `bench` — one CLI, which is also the agent skill.**

Every verb, addressed, symmetric: `bench spawn|close|move|split|open|capture|mail|task|
watch|state`. Ship it with a SKILL.md that teaches the surface (herdr does this;
helm's `.claude/skills/` already is this), gated on `BENCH_PANE` being set — capability by
environment, herdr's `HERDR_ENV` rule. The conformance-test culture ports whole:
`SpoolWireConformanceTests`' shape — run the real binary, check both directions, every
status case — is the right gate for this CLI.

### The protocol decision: pty-first, ACP-sidecar

Host every agent two ways at once:

- **The pty is the agent's face.** The field is unanimous that the TUI the agent teams
  ship is better than a rebuilt chat, and helm's own measurement (transcript grain, the
  silent pending question) says a file-based chat face can't work. Keep raw terminals.
- **ACP is the agent's nervous system.** Alongside the pty, benchd connects to each agent
  via its ACP adapter (`claude-code-acp`, `pi-acp`, codex's) where available. That yields,
  as *events*: the pending permission request (routable to the bench UI or the phone,
  answerable without touching the pane), tool-call activity (working/idle for free, no
  output sniffing), plans, session ids for resume. Agents without ACP degrade to herdr-style
  process/output classification.

This dissolves three helm problems at once: the chat face becomes viable (render the ACP
stream, not the transcript file), attention states become facts instead of heuristics, and
#283's silent 6.5h stall becomes impossible — a permission request that reaches no
unattended posture becomes a visible, answerable attention item instead of a stuck pane.

### Attention: the queue, not the seizure

The one genuinely new subsystem, because it is what "equal owners" trades for the keyboard
rule. Every agent action that wants the operator lands in one queue with a type:

- `blocked` — permission request, question, plan awaiting approval (from ACP, or from a
  mail message flagged as such);
- `done` — task finished, PR opened, artifact pushed;
- `offer` — "I put a canvas beside my pane; look when you like" (helm's #284 bring-forward
  question, answered: an offer is a badge, never a focus change).

The operator gets: per-pane state color (herdr's four states), an unread count, one
keybinding to jump to the oldest `blocked` item (cmux's ⌘⇧U), and push notifications for
`blocked` items older than N minutes. Agents get the symmetric read: `bench watch` blocks
until a named peer is *genuinely* blocked or done (herdr's `agent wait`) — which replaces
polling-by-wake and lets FirstMate-style zero-token supervision work: a watcher process,
not a model turn, decides when a supervisor agent needs to wake.

### Coordination: interoperate, don't reinvent

- **Mail**: keep the file mailbox as the canonical record (it is transport-neutral and
  survived contact with three runtimes), but make **delivery** transport-aware: for a
  Claude Code recipient, benchd forwards the notice to the session's messaging socket, so
  mail *wakes* an idle session as a real user turn — no armed watch, no polling, no wake
  budget spent by the sender. pi keeps its in-process wake; a runtime with neither channel
  falls back to deliver-before-turn. benchd also registers bench-hosted peers on the
  discovery path so `ListAgents` sees them. Keep helm's hard-won rules verbatim across all
  transports: notice carries path never body, `operator` reserved, retire never delete,
  loop caps on agent↔agent chatter (CC's own throttling plus a bench-side cap).
- **Tasks**: adopt the file-locked-claim shape Claude Code teams standardized (a task file
  claimed by atomic rename — which is exactly the spool's claim semantics) rather than
  inventing a scheme. A shared task list with dependencies is what makes "equal owners"
  mean something day-to-day: either party posts work, either party claims it.
- **Worktrees**: a pattern, not a primitive (cmux's "primitive, not solution" and helm's
  equal-standing rule agree). `bench spawn --worktree` composes the primitive; the bench
  never requires isolation it didn't ask for.

### The document surface: keep the moat

Nothing in the field has helm's canvas, and the greenfield design keeps all of it as-is,
ported: artifacts are files; push is a verb (now `bench open <path> --beside <pane>`, no
OSC fragility — #282/#124/#184's whole bug class dies with the daemon socket); annotation
classifies gestures against DOM anchors and returns as operator-mail; the state latch
stays a latch (a page speaks to the *next turn*, never into a live prompt); operator notes
stay the one operator-writable path; agent artifacts stay read-only to helm. These rules
were all bought with measured incidents and none of them is invalidated by equal
ownership — they are about *files*, and file ownership was never the asymmetric part.

### What not to build

- **A browser driver** — playwright exists; cmux's embedded automation browser is the one
  feature of theirs I would not copy first (it's a second product).
- **An agent** — helm's rule stands: host CLIs, never build one. The intelligence stays in
  skills and the agents themselves.
- **A rich chat editor/composer** — render the ACP stream read-only beside the pty face;
  typing still goes to the agent's own TUI, which already handles interrupts, modes,
  slash-commands.
- **Auth between agents** — same-user filesystem is the trust boundary, stated plainly
  (helm's position, and Claude Code's own local-socket position). Equality needs
  addressing, not identity papers.

### Build order

1. **benchd owning ptys + attach protocol + `bench` CLI** — the herdr core. Survival
   across app restart is the switch-over line (the greenfield analogue of helm's
   position 1).
2. **Mac shell rendering attached terminals** in helm's bench model (columns/slots/tabs,
   ported values and placement policies).
3. **ACP sidecar + the attention queue** — states, unread, jump, phone push.
4. **Mail + tasks with the Claude Code bridges.**
5. **Canvas port** (webview, annotation, latch, notes).
6. **Fleet ergonomics** — `bench watch`, zero-token supervision, worktree composition.

### And if not greenfield

The audit's honest conclusion: helm's *values* — the bench model, the policies, the wire
types, the canvas, the mailbox rules, the test culture — are the durable 60%, and they are
values precisely so they can move. The 40% that the field has now falsified is the process
topology (GUI owns ptys) and the thinness of attention. A helm-evolution route exists:
extract benchd from `TerminalManager`+`SpoolModel` behind the existing protocol seams
(`SpoolSpawning` et al. were built for exactly this shape of replacement), move pty
ownership behind it, and adopt ACP as the chat face's source. That is more work than it
sounds (libghostty surface ↔ external pty is the hard seam) but it is not a rewrite — and
every conformance test keeps meaning something across the move.

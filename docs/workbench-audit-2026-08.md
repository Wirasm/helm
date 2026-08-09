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

- the ptys and their VT state — a VT *library* (libghostty-vt, or the `wezterm-term`
  crate: the parser/screen model WezTerm is built on, no app or window involved) embedded
  in the daemon, so scrollback and screen state live server-side and any client renders a
  grid snapshot + diffs. A terminal is three layers — pty, VT state, painter — and only
  the painter lives in the face: **the terminal the operator sees and types into is still
  SwiftUI, in the one app**. benchd is not a second app; it is the app's engine moved
  out-of-process, so the state survives the app;
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

**Own daemon, not tmux underneath.** tmux covers only pty custody + persistence + attach
— the best-understood slice of benchd — and it is the wrong foundation for three
reasons. (1) The rendering seam: a native face needs grid state, so tmux means control
mode — subscribing to `%output` and re-parsing escape streams into your own VT state,
iTerm2's most fragile subsystem — at which point tmux holds file descriptors while you do
the hard part anyway. (2) The model mismatch: binary splits inside windows cannot carry
columns-of-tabbed-slots or canvas panes; the sane mapping is one window per pane with
tmux's layout ignored, i.e. tmux demoted to `posix_openpt` with baggage. (3) The killer,
policy: tmux's socket is an unguarded second door — `send-keys` reaches *any* pane,
including the operator's, which is precisely the wrong-terminal-keystroke class the
refusal rules exist to eliminate, and tmux has no vocabulary for `holdsKeyboard`. Keeping
the constitution means hiding the socket, which forfeits tmux's one real advantage
(agents already know it). The native core is `portable-pty` + libghostty-vt/`wezterm-term`
+ scrollback + launchd — herdr is one developer's proof this ships. tmux's honest role is
week-one scaffolding: prove the spine against control-mode panes, behind an API that lets
the pty core swap in without anything above it noticing.

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

### The protocol decision: pty-first, with the stitched taps as the nervous system

**The pty is the agent's face.** The field is unanimous that the TUI the agent teams ship
is better than a rebuilt chat, and helm's own measurement (transcript grain, the silent
pending question) says a file-based chat face can't work. Keep raw terminals.

**ACP is not the answer here, for two reasons found the hard way.** First, ACP is
host↔agent, not agent↔agent — it has no peer messaging and cannot be the comms system.
Second, and sharper: ACP adapters *replace* the TUI rather than attach to it —
`claude-code-acp` wraps the Agent SDK and runs the loop itself, with the host rendering
the transcript. There is no way to connect ACP to an already-running interactive TUI in a
pty, so pty-first and ACP are either/or *per session*. For this bench it buys nothing at
all, because the design has no headless sessions to give it: **every agent, on every
machine, runs as a full interactive top-level session in a benchd-held pty** — never
`claude -p`, never `codex exec` — precisely so it can be attached to from the Mac and
look identical to sitting at the box. One benchd per machine is the landlord; each agent
session is a tenant with its own pty, lifecycle and address — the per-agent-daemon effect
without N processes to supervise. Resume after a reboot is interactive too: benchd types
`claude --resume <id>` into a fresh pty, the same move as helm's `cls --resume`.

**The structured-event feed comes instead from the layer the operator already runs —
hooks, the spool, the mailbox, the pi extension — given a spine.** That stitched system
is the right architecture, not a stopgap (Claude Code's own teams feature is inbox files
plus file-locked claiming; its cross-session messaging is a socket with disk discovery —
the same trust model). Its flakiness is N pairwise stitches with no single owner: hook,
extension and spool each half-know the world and reap each other by convention. benchd is
the fix: every tap reports to one daemon that owns registry, liveness and delivery, and
the per-runtime bits shrink to dumb sensors:

- **Claude Code**: the `Notification` hook fires precisely on "needs permission" and
  "waiting for input" — that *is* the `blocked` event; `Stop` = done, `PreToolUse` =
  working; the messaging socket is the wake path.
- **pi**: the extension's event loop already sees everything; it forwards states.
- **codex**: the `notify` config (approval-requested, turn-complete) plus herdr-style
  output classification as fallback — the weakest tap, and the one place sniffing stays.

#283's silent 6.5h stall dies here regardless: a permission request no unattended posture
covers becomes a visible, answerable attention item instead of a stuck pane.

### Attention: the queue, not the seizure

The one genuinely new subsystem, because it is what "equal owners" trades for the keyboard
rule. Every agent action that wants the operator lands in one queue with a type:

- `blocked` — what this means is defined by the bench, not by any runtime's approval UI,
  because the operator runs wide-open postures and harness permission prompts essentially
  never fire. In yolo mode blocked is: *ended its turn on a question* (CC `Stop` hook +
  transcript-tail classification; pi sees the message itself; codex falls to the
  sniffer), *stalled* (no output and no turn-end — the blind-stop case), *idle with
  unread mail*, or *errored*. The `Notification` hook's waiting-for-input signal
  contributes without being the headliner. Approvals exist only as **voluntary decision
  gates**: an agent posts a `decision` item (`bench attn post --kind decision`) because a
  skill or house rule says that act is gate-worthy — per host, so the forge gates almost
  nothing and the Mac maybe gates merges. The operator is never asked by the harness;
  they are petitioned through the bench;
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
  budget spent by the sender. pi keeps its in-process wake. **The mailbox itself is
  runtime-neutral — every agent sends and reads the same way; only the wake hop differs**
  — and benchd's pty ownership supplies the universal fallback no outside process could
  do safely: for a runtime with no wake channel (codex today), benchd pastes the mail
  notice into the TUI's composer and submits it, guarded by the tap's idle-prompt check
  (the spool launch-line move: paste, then Return separately; refuse while busy). So
  woken delivery is the semantics on every runtime; the transport is a detail. benchd
  also registers bench-hosted peers on the
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
- **Subagents: the spawning mechanism is the agent's choice, and the bench only tiers the
  visibility.** A top-level agent may spawn runtime-internal subagents (Claude Code native
  subagents/teams, codex subagents, pi's own) or pty-level peers through `bench spawn` —
  the bench prescribes neither. Runtime-internal spawns live inside the parent's runtime
  (its context, budget, cleanup); benchd does not manage them but *sees* them through the
  parent's tap — CC teams fire `TeammateIdle`/`TaskCreated`/`TaskCompleted` hooks and
  write inboxes to disk — so even invisible subagents feed the attention queue, and
  benchd may *offer* to materialize a teammate as a pane when team config appears (cmux's
  Teammate Mode, under the offer rule). Pty-level peers are full tenants: own pty, handle,
  mailbox, bench-document row, attachable like everything else, with the spawn result
  carrying `terminalId`/`sessionId`/`handle` so supervising needs no lookup — and closing
  a teammate's pane stays legal, as in helm. Caps apply per tier: bench-side limits govern
  pty tenants; the runtime's own knobs (CC spawn depth/concurrency) govern internal
  subagents. Neither route is taxed for not being the other.

### Orchestration: a tenancy pattern, and NOT part of the app

**Read this section as a boundary, not a spec. The orchestrator hierarchy has nothing to
do with the app, and must never be architected into it.** There is no orchestrator kind,
role, rank, team, or supervisor field anywhere in benchd, the wire contracts, the CLI,
or the face — and a future session working from this document must not add one. The
bench knows tenants; that every tenant is equal is the constitution, and a hierarchy
type would be its first violation. If a future change seems to need the bench to know
who supervises whom, the answer is a skill or a prompt, not a field — the same rule helm
already holds ("helm renders and routes; it does not decide"), kept on purpose.

What the operator actually runs on top — one orchestrator agent per project, maybe one
above those later — is **entirely convention**: an ordinary tenant whose authority over
workers is its prompt and its skills. It composes the generic primitives every tenant
has: `bench spawn` (workers as attachable TUIs the operator can always look in on),
tasks posted and claimed by rename, briefs and reports as mail across hosts, and
`bench watch` for zero-token supervision (a watcher process, not a model turn, wakes it
only when a worker is genuinely blocked or done). Because none of that is structural,
the operator can kill an orchestrator, bypass it, run two against one project to A/B
their prompts, or talk to any worker directly — nothing breaks. Iterating the hierarchy
— per-project orchestrators, later a first mate above them — is a prompt change, never a
bench change. This is helm's #186, run on the bench rather than built into it.

One deliberately generic mechanism is adjacent and must stay generic: an attention item
can be **addressed to any tenant's queue** — the same symmetric addressing mail has, so
a worker's skill can say "post your blocked items to <handle>". That is addressing, not
hierarchy: the daemon stores no notion of who routes to whom, the sender names a
recipient per item, and the operator's queue can always show everything. If that field
ever grows orchestrator-shaped semantics — default supervisors, escalation chains,
role-aware filtering — it has crossed the line this section draws.

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
- **A rich chat editor/composer** — the pty face is the interface; a read-only rendered
  view, if ever, comes from transcripts plus the event taps, accepted as seconds behind.
  Typing goes to the agent's own TUI, which already handles interrupts, modes,
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
3. **The runtime taps + the attention queue** — states, unread, jump, phone push.
4. **Mail + tasks with the Claude Code bridges.**
5. **Canvas port** (webview, annotation, latch, notes).
6. **Fleet ergonomics** — `bench watch`, zero-token supervision, worktree composition.
7. **The second benchd** — the agents' own machine (below).

### Two benchds: the agents get their own machine

The daemon/renderer split makes the strongest version of "equal owners" a topology, not a
metaphor: benchd on the Mac, a second benchd on a small always-on box the agents own,
peered over Tailscale/SSH. What changes:

- The Mac sleeping no longer kills the fleet; the Mac is an attach point, not the ground
  the agents stand on.
- The mailbox stays files-as-record on each daemon's disk; **delivery** goes
  daemon→daemon, and handles grow a host qualifier (`sild-a3f2@forge`). Claude Code's
  messaging sockets are same-machine, so cross-machine wake is benchd's job: relay to the
  remote daemon, which pokes the local socket.
- The trust boundary is stated honestly: same-user filesystem *within* a machine, the
  peering link's identity *between* machines. Still no auth between agents on one box.
- Ownership becomes per-host policy with teeth: the agents' box runs wider unattended
  postures and a wider command allowlist than the Mac. The operator-protecting refusals
  exist where the operator's keyboard is, and nowhere else.

The operator's own machine plan maps onto this one-to-one. **Machine 1** (MacBook/iPhone,
control plane) = the attach clients: face, `bench attach` over Tailscale, phone —
"approve sensitive actions" becomes the attention queue rather than ssh-and-hunt.
**Machine 2** (Linux agent box) = the forge; the `tmux / herdr / cmux` slot in that plan
is exactly the slot benchd fills, and its `~/worktrees/<product>-agent-NN` layout is what
`bench spawn --worktree` composes. Docker stays an optional per-task isolation posture,
orthogonal to the daemon. **Machine 3** (future local inference) sits below the bench's
abstraction line: benchd never knows which model an agent talks to, so vLLM/Ollama are
endpoint config on the CLIs (an Anthropic-shaped proxy for Claude Code), swappable
per-agent without touching the bench. Three consequences the plan settles: benchd and the
CLI/TUI must be **Linux-first** (which also settles the daemon language: Rust); the
design must be **machine-count invariant** — day one is everything on the Mac, adding the
forge is the same binary plus a policy file plus `bench peer add`, topology as config;
and "the agent machine may become messy" gets one exception — `~/.bench/{mail,events,
tasks}` and the artifact stores are the fleet's memory and get backed up, one cron line.

### Decisions taken, and what stays open

Four of the six open questions are settled (operator, 2026-08-09); two remain.

1. **Cross-host verb scope — DECIDED: verbs are host-local; helpers live where they
   help.** Cross-host traffic is petition-only, always: mail, attention items, tasks.
   There is no per-peer flag and no exception machinery — when the operator wants agent
   help operating the Mac bench, that agent runs *on the Mac* and holds Mac verbs as an
   ordinary local tenant. Locality is the permission. Corollary on contracts: the verb
   set stays terse enough to be self-describing — `spawn`, `close`, `move`, `open`,
   `mail`, `attn`, `watch`, `attach` — and every result leads with one word
   (helm's status-plus-reason shape, kept).
2. **Cross-host artifacts — DECIDED: benchd is a private artifact server, and the
   tailnet is the authentication.** benchd serves artifact bytes the way it serves
   grids, relayed over peering; the face renders a forge artifact with no local path.
   **Tailscale device identity is the whole auth story** — the operator's devices are on
   the tailnet, nothing else is, and nothing ever asks for a login. It behaves like a
   published artifact with an audience of one, where the audience check is "from my
   tailnet." The canvas port's scheme handler therefore reads via the daemon, not the
   filesystem. The canvas is a collaboration surface, agent-owned first: agents write
   and re-push, the latch speaks back, the operator annotates — daemon-serving just
   makes that location-independent.
3. **benchd restart vs. pty survival — DECIDED: accept the resume-storm; the shim stays
   parked.** Upgrade = drain, restart, interactive `--resume` per session. The one case
   where restarts get frequent is agents developing the bench itself, and helm already
   built that answer: port the isolated suite (`HELM_DEFAULTS_SUITE`, #86) as
   `BENCH_SUITE=<name>` — a second, fully isolated benchd (own socket, own record, own
   panes) agents test against while the live one hosts them. The per-session pty-holder
   shim is named as the known path only if upgrade frequency ever proves it. Posture
   underneath, stated as principle: **the agents own the bench's evolution** — they add
   the capabilities they need themselves, gated by the PR, and a restart of the Mac's
   *live* daemon is announced through a decision item first (the "never restart a
   running helm without warning" rule, inherited).
4. **Agent credentials — DECIDED: one shared agent identity.** The agents collectively
   get a shared GitHub account and shared keys. The trade — per-agent audit granularity
   for simplicity — is right at this scale, because the boundary that matters is
   *agents vs. operator*, and it stays crisp: the agents' account's PRs are theirs, the
   operator's approvals are the operator's, and blast radius is bounded by one account's
   scopes rather than the operator's own credentials scattered across a fleet.
5. **OPEN — limits and spend in the taxonomy.** `limited` (usage/rate limit hit) is a
   `blocked` subtype the overnight fleet will produce; budget visibility is helm's #143
   wearing its real clothes. Add to the attention taxonomy early.
6. **OPEN — queue triage at scale.** The first morning brings dozens of items; the event
   log makes a digest a pure projection (since-you-left counts, grouped by project and
   by addressee — which covers orchestrators with no hierarchy in the app). A view,
   built early.

Carry-over: helm's #297 (OSC 52 clipboard overwrite) moves into the face's painter —
hostile-output handling becomes a renderer decision made once, the better place for it.

### How to build it — DECIDED: strangler, in this repo

One git project, so agents work across the whole stack in one checkout — and because the
conformance-test culture requires it: every wire contract has a Rust truth and a Swift
speaker, and only a monorepo lets one PR change both sides atomically under a test that
runs both. Layout: `daemon/` as a cargo workspace (`benchd`, `bench` CLI, `bench-wire`),
with its own gate run only when touched — the same carve-out as `pi/` and `hooks/`, so
the Swift gate keeps needing only the Swift toolchain. Rust is the single spelling of
every wire type; the Swift side is generated from it, or where codegen fights, a
conformance-pinned duplicate under the repo's existing honest-duplicate rule.

Replace one vertical at a time, old code unwired only when the new is proven — and the
first step is *additive*, so the new stack is proven before anything old is touched:

1. `daemon/` skeleton + `BENCH_SUITE` isolation from day one (agents build this on the
   machine that hosts them).
2. **Add** the taps → attention queue → `bench attn`/`watch`; helm renders the queue.
   Zero unwiring; daemon, socket, CLI and taps all proven.
3. Mail authority moves to benchd (registry, liveness, delivery, cc-socks wake); hooks
   and the pi extension thin to sensors. Unwire the delivery halves.
4. The wire front moves: `bench` CLI + socket replace `tools/*.swift`, with benchd
   forwarding into helm's spool during transition; the conformance tests retarget and
   prove parity before the scripts die.
5. The bench document moves to benchd; helm renders daemon state but still hosts ptys
   through the `SpoolSpawning`/`TerminalLaunching` seams — the substitution those
   protocols were built for; this step is why the migration is not a rewrite.
6. Ptys move last, **per-pane**: painter panes over daemon grids coexist with libghostty
   panes on one bench until the last old pane is gone — then unwire the vendored patch
   and the ownership half of the terminal stack. The forge follows for free.

Apply the repo's own discipline to each unwiring: watch the old path fail after removal,
name which tests proved parity, and revert with `git checkout <base> -- <files>` when a
step lies. helm strangles itself along its own seams and ends the migration as the face.

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

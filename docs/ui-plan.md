# Cockpit UI — where we're headed (handover)

Status: **planning + a partial slice in flight** (uncommitted in `app/`, see "In flight").
This is a context handover, not a spec. Build minimal, expect churn — we're experimenting.

---

## The vision (as Rasmus framed it)

> what I'm imagining is basically
>
> a chat interface
> - projects on the left
> - main agent session at the top
> - workstreams on the left but right of projects
> - workstreams, main session, and sessions under the workstream so we can up/down
>   arrow into each running session to see it
>
> idk just ideas

That sketch is the north star. It's conversation-first, and it makes the **operator
session** (what the sketch calls the "main agent session") a first-class surface — you talk
to it up top, and the rooms it opens appear below so you can arrow into them.

---

## The principle it must honor: Deliver Signals, Not Sights

This landed as a CLAUDE.md principle from a real incident (see `feat(room): idle failsafe
assumes no one watches the roster`):

> Assume the operator is an agent (a pi driver, another orchestrator); the cockpit human is
> the special case. Anything that matters must arrive as an explicit deliverable — a post
> with recipients, an event to the opener, a nudge, a ledger entry. UI visibility is a
> courtesy for whoever happens to be watching, never the contract.

What this means for the UI: **the cockpit is the "someone happens to be watching" surface.**
It must never be load-bearing for correctness (the engine already delivers signals to
agent-operators). But when a human *is* watching, the cockpit's job is to make all the
rooms legible at a glance — which is exactly the Fog-lifting the engine can't do for a human.

---

## Where the UI is today (~2,900 lines, Tauri + SvelteKit)

A working room-centric cockpit exists:
- **One left sidebar** stacking projects → rooms → worktrees in a single 240px column.
- **Room view**: the shared room log + the focused participant's "working detail" in a
  50/50 split; participant chips; on-the-fly invite.
- **Composer**, **Topbar** (focused agent's name, model, branch chip, ctx%/tokens/cost).
- Modals for new project / new room.
- Live WS reconcile with the engine; archived-room browsing.

The transport and reconcile logic are decent. The information architecture and the data it
surfaces are the weak parts.

## Gaps (ranked by how much they hurt)

1. **None of the observability we built reaches the UI.** git state (ahead/behind/dirty/
   **conflicts**), cross-room **collisions**, per-agent **models** in the roster, the
   **spawn tree** (`invitedBy`), room cost rollup — all on `/api/rooms/live`, none rendered.
   The cockpit's reason to exist is lifting the Fog, and the Fog-lifting data isn't shown.
2. **No attention surface.** Nothing says *which room needs you* — a lead posting to
   `@human`, a blocker, a report-and-idle "done, waiting." With report-and-idle as the
   lifecycle, "finished, waiting for you" is now the most important state and the UI can't
   express it (just a running/stopped dot).
3. **No operator tier / no "main session."** Detached operator sessions and plain sessions
   are invisible (nothing consumes `/api/sessions`). The "main agent session at the top"
   concept from the sketch doesn't exist yet.
4. **Zero keyboard navigation.** The up/down-arrow-into-each-session idea — not there.
5. **Hardcoded, stale model list** in the spawn modal (`claude-sonnet-4-6`, `gpt-5.5`…),
   disconnected from the config **model catalog** the fleet actually uses.
6. **Participant transcripts are ephemeral** (in-memory). Join a CLI/pi-opened room late —
   which is now the normal flow — and "working detail" is blank forever.

## What's design-shit right now (opinionated)

- **Sidebar IA**: projects, rooms, worktrees as three flat lists in one column. Rooms are
  the core object but read like anonymous log lines (`@agent` / "3 agents" + project name) —
  no goal/title, no last-activity, no needs-attention. Worktrees as a sibling section is
  redundant (a worktree is a room's *property*).
- **One-click ✕ close on every room row, no confirm.** We just established closing is
  destructive and human-explicit — the UI makes it the easiest misclick in the app.
- **The 50/50 room/participant split** buries what you care about (what the *room* decided)
  behind the focused agent's token stream. Room log should be primary; working detail a
  drill-in.
- **UI-vs-CLI schism** (`origin: "ui" | "cli"` + `ownedIds`) half-treats CLI/pi rooms as
  second-class, instead of the engine being the single source of truth.

---

## Target layout (the sketch, made concrete)

```
┌──────────┬─────────────────────────────────────────────────────┐
│ projects │  MAIN SESSION (the operator — persistent chat)      │  ← top strip
│  (thin)  ├──────────────────┬──────────────────────────────────┤
│          │ rooms tree       │   selected session's view        │
│  archon  │ ▸ fix-2247   ⚠   │   (room log, or an agent's        │
│  kild    │   ├ agent  sol ● │    transcript; composer at bottom)│
│  sasha   │   ├ analyst terra│                                  │
│          │   └ explorer t.  │   right rail (collapsible):       │
│          │ ▸ feat-x     ✓   │    git: dev +2 dirty CONFLICTS    │
│          │                  │    collides: feat-x (2 files)     │
│          │                  │    cost roll-up · spawn tree      │
└──────────┴──────────────────┴──────────────────────────────────┘
```

- **Projects** — thin far-left rail (names/icons only).
- **Rooms tree** — rooms under the active project, each expandable to its **sessions
  (participants)** with model + running/idle/**needs-attention** dot. **↑/↓ walks every
  session across rooms; →/← expands/collapses.** The engine already streams every
  participant's transcript — the UI just needs focus-follows-selection.
- **Operator session on top** — a resident **operator session** (sol, holding the
  room-control tools). The engine already supports spawning exactly that
  (`POST /api/sessions {fleet:true}`). The top strip is your standing chat with it; rooms it
  opens appear in the tree below. This unifies "human operates" and "agent operates" into one
  surface — the VISION.md sentence, made real, and consistent with Deliver-Signals (the
  operator is an agent; the human just watches/steers it).
- **Right rail** — the observability payoff per selected room: git/collision/cost/
  spawn-tree.
- **Attention model** — rooms sort needs-you-first (lead→@human / blocker / idle-finished),
  with a badge. Close moves behind a confirm, away from the row.

---

## Build order (minimal slices, independent where possible)

1. **Observability into the UI** — types + right rail + roster models + idle state. Data is
   already on `/api/rooms/live`; pure rendering; immediate payoff. *(Slice 1 — partly done,
   see In flight.)*
2. **Sidebar → rooms tree + keyboard nav** — the ↑/↓ session walker; restructures the
   IA around rooms. *(Slice 2.)*
3. **Attention states + safe close** — needs-you badges, idle-finished first-class,
   confirm-to-close.
4. **Model catalog into the spawn modal** — kill the hardcoded list; serve the config
   catalog (a tiny engine endpoint, or reuse what the pi extension reads).
5. **Operator session strip** — the resident sol chat. Biggest new concept, most
   valuable; do it after 1–2 have reshaped the frame.

Do 1 + 2 first: they're independent of any design debate and fix the worst of it.

---

## In flight (uncommitted in `app/`)

A partial **Slice 1** is sitting uncommitted in the working tree (`git status` shows
`app/src/lib/types.ts`, `app/src/lib/api.ts`, `app/src/routes/+page.svelte`):
- `types.ts`: added `GitStatus`, `Collision`, `LiveRoomStatus`; `git`/`collidesWith` on
  `Room`; `model` on the participant view.
- `api.ts`: `listLiveRooms()` now returns `LiveRoomStatus[]`.
- `+page.svelte`: `mkParticipant` carries `model`; `recomputeCollisions()` (client-side
  changed-file overlap); `mergeLiveLog` folds in `git` + resolved model; `reconcileRooms`
  fills models; a `selectSession(roomId, participant)` handler (the tree/keyboard target).

**Not yet wired:** the Sidebar rooms *tree*, the keyboard nav, and the right rail that
renders the git/collision data. So the data model is ~ready but nothing new is shown yet —
`app/` won't cleanly build as a finished feature until Slice 1's rendering + Slice 2 land.
It's uncommitted, so it blocks nothing.

---

## Open questions (decide before Slice 5)

- **Operator session**: auto-spawn with the cockpit, or explicit "start operator"? Per
  project or one global operator? What model (sol by default)?
- **Attention priority**: what exactly ranks a room "needs you" — only `→@human` posts, or
  also idle-finished, collisions, conflicts-with-base?
- **Does the cockpit ever *drive*, or only *watch + steer*?** Deliver-Signals says the
  engine owns correctness; the cockpit is the human's window. Opening/closing rooms from the
  UI is fine (human is an operator), but keep it a courtesy surface, never the contract.

---

## Addendum 2026-07-24 — new engine primitives the UI should lean on

Landed on `feature/project-memory` (PR #663): keyed decisions, pi resume handles,
project/fleet memory. Three of them reshape slices 3+ — for the better, because the UI
stops guessing and starts rendering engine truth.

### Attention is now structural, not heuristic

The engine holds a keyed decision ledger per room (`needs-decision[key]: …` opens;
only `resolved[key]: …` closes; open decisions block close). So the "needs you" ranking
stops being a UI heuristic:

1. **Open decision** (`room.decisions` unresolved) — a badge with the key + question.
   The room literally cannot close until someone answers.
2. **Unanswered `→ @human` post** — the lead reported/asked and nothing followed.
3. **Idle-finished** — every participant idle after a delivered report (report-and-idle
   is the lifecycle's "done, waiting for you").
4. **Git trouble** — CONFLICTS with base / cross-room collisions.

"Resolve" is a first-class UI action: a button on the decision badge that composes a
`resolved[<key>]: <note>` post into the room. No new endpoint — it's just a post.

### Safe close now has engine teeth

`close` refuses while decisions are open (operator `force` overrides). The confirm
dialog writes itself: show the open decisions in the dialog, force = explicit checkbox.
The UI never decides what's safe — it renders the engine's refusal.

### "Open in terminal" replaces the cmux/herdr itch

Every participant (live and archived) now carries `piSessionId`/`piSessionFile`. Per
session row: a copy-button for `pi --session <file>` (archived/dead → resume; live →
offer `pi --fork <file>` instead, with a hint that forks are interrogation copies —
never `--session` a live agent, two writers one file). The cockpit is the crew wall;
the terminal is the escape hatch.

### Memory as a project surface (later, cheap)

Per project: `.kild/LOG.md` is a ready-made room-archive browser (one entry per
closed room: goal, outcome, decisions, resume handles) and `.kild/MEMORY.md` /
`direction.md` are the project's brain. A read-only "memory" tab on the project view
renders all three. Engine-side it may deserve a tiny `GET /api/projects/:name/memory`
rather than the Tauri shell reading files directly.

### Open questions — recommendations

- **Operator**: explicit "start operator" (auto-spawn = surprise token spend), one per
  project, model from the config catalog (first entry as default) — never hardcoded.
- **Attention priority**: the structural ranking above; open decisions outrank everything.
- **Drive vs watch**: watch + steer. Every UI action is an operator action that already
  exists engine-side (open/post/invite/close/resolve). Courtesy surface, never contract —
  unchanged, now with better data.

---

## Addendum 2026-07-24 (2) — transcript gems + two direction changes

Source: Archon feedback session 2026-07-23 (Rasmus/Matt/John). Two decisions supersede
parts of the plan above; the gems justify a new slice.

### Decision: the main view is a TERMINAL, not an operator strip (supersedes slice 5)

The "main agent session strip" (engine-spawned resident operator) is dead. Instead:
an embedded real terminal (xterm.js + Tauri pty) where you open pi / Claude Code / codex
— whichever harness has credits — and that harness drives kild via its existing
skill/extension/CLI. The rest of the cockpit is the view + control into kild itself.
Toggle terminal view ⇄ kild view.

Why: the operator rotates by inference economics (Claude Code → Opus+kild → pi someday);
a bespoke operator chat would freeze one harness into the UI. This kills slice 5's open
questions (auto-spawn? which model? per project?) entirely.

Rules that keep it clean:
- **Host the terminal, never scrape or inject.** The pty is opaque to the UI; everything
  the operator does materializes through the engine (rooms/posts/WS), which is what the
  kild view renders. Handing context to the operator = explicit copy-to-clipboard, never
  send-keys. (Inverting firstmate: hosting is safe, scraping was the tax.)
- The pty lives outside the webview lifecycle — view toggles never kill the operator.

### Decision: the plan/review canvas is backend-agnostic via the filesystem

Plan and review canvases are "different backends feeding the same UI" — but the canvas
must not grow per-backend adapters. Contract:
- **Artifact source = a markdown file** (+ frontmatter). PRP plans, Archon workflow
  outputs, review reports, kild LOG/MEMORY — all already land as files. Anything that
  writes markdown feeds the canvas for free.
- **Feedback sink, chosen per artifact**: paste-to-terminal · post-to-kild-room ·
  write-back comments file. New backend later = new sink, not a new canvas.
- **`session:` frontmatter** records the authoring session handle (rooms: already in
  LOG.md via pi resume handles) — the hook for frozen-fork Q&A.

### Gems → the artifact-canvas slice (promoted ahead of everything after slice 3)

1. **Select-text → comment → batch into ONE prompt** back to the authoring session
   (kills the scroll-up-answer-scroll-down loop). Matt has this working via tmux
   send-keys; ours routes through a feedback sink instead.
2. **Frozen-context Q&A**: per-question `pi --fork <sessionFile>` from the pinned
   authoring session — question 1 never pollutes question 10; discard forks by default,
   "promote this insight" posts a distilled note into the live session. Fast models
   (cerebras/minimax) can serve the forks for interactive latency.
3. **The review spec in one sentence**: "what I need to see, in the order I need to see
   it, with the decisions I need to make." The decisions clause is structural now (open
   `needs-decision[key]` items + inline inputs → batched `resolved[key]:` posts).
   Later, Matt's variants: diff grouped by purpose (data models first); approve-by-file-
   hash, re-review only on change.
4. **Diagram toggle**: render the plan's draw.io/mermaid diagram beside the artifact
   (current practice: generated after every PRP plan, viewed in the IDE).
5. **direction.md validated by field use**: the Archon direction.md is mostly *rejection
   reasoning* — the memory synthesis charter should explicitly capture what was rejected
   and why, not only what was decided.

### Revised build order

1–2. Observability rendering + rooms tree/keyboard nav (in flight, unchanged).
3. Attention + safe close (now engine-backed: open decisions, close refusal).
T. Embedded terminal + view toggle (replaces old slice 5).
C. Artifact canvas v1: file-based markdown render, select-to-comment, batch feedback
   → sink; decisions list with inline resolve. Then: frozen-fork Q&A, diagram toggle.
4. Model catalog into the spawn modal (unchanged, still small).

Moral from the call (Matt): stop building, use it, then build — ship each slice and
dogfood before the next.

---

## Addendum 2026-07-24 (3) — the UI leaves this repo; artifacts leave kild

Direction decided with three moves that supersede much of the above as *location*,
while keeping the IA/slices/canvas thinking as the seed plan:

1. **Artifacts/memory move to the intelligence layer**: `~/.prp/<project-key>/` (PRP
   reshape, planned in the PRP repo). kild keeps mechanism state only and gains a
   configurable `memory.dir` (default `.kild`) used by the close-hook, injection, and
   LOG.md — kild never learns what PRP is. PR #663 merges as-is; `memory.dir` is the
   follow-up. Project keying: canonical main-checkout path slug + `~/.prp/projects.json`
   index; worktrees resolve via `git rev-parse --git-common-dir`.
2. **No separate planning API.** Filesystem = artifact API; kild engine = session API.
   One missing mechanism: fork-spawn (`POST /api/sessions` from a session file) for
   frozen-context Q&A — small engine addition, not a new server.
3. **The cockpit becomes a separate native project** (working name kild-ui): SwiftUI +
   libghostty terminal as the main view (macOS; an iOS companion later is observe/steer/
   canvas only — no terminal), webview islands for draw.io/excalidraw/mermaid, native
   markdown, OS triggers/hotkeys/TTS. The engine REST/WS API is the ONLY contract.
   The Tauri/Svelte cockpit + in-flight slice 1 are parked, not merged; this doc is the
   salvage and seeds the new repo's plan.

---

## Addendum 2026-07-24 (4) — terminal workspace lands; review UI deliberately deferred

- **Review surface**: engine git-facts endpoints exist (#668); the review UI is
  DELIBERATELY deferred until designed against real dogfooding — do not build it
  speculatively.
- **The terminal-workspace model supersedes the drawer idea**: the main view is a
  terminal WORKSPACE — N terminal tabs (each an independent login shell, ptys owned
  app-level by `TerminalManager` so they survive any view churn) plus an optional
  read-only artifact split beside them ("operator in the terminal, plan beside it":
  ⌘O opens a file, .md renders formatted, re-renders on external change). The kild
  view is unchanged. Shortcuts: ⌘T face toggle, ⌘N new terminal, ⌘1–⌘9 select tab,
  ⌘O open artifact.

---

## Addendum 2026-07-25 — simplification round + parked layout rethink

Owner direction after living with the artifact viewer: SIMPLIFy. One webview renders
md+mermaid per document (no islands, no per-diagram sizing/toggles/sheets — vendored
marked + mermaid, whole-document zoom via webview magnification); "doesn't fit" is a
window-size concern. Browser = select project → flat artifact list + Browse (no
recents/filter/ages). Fence scanning exists only for chat bubbles.

PARKED for after cleanup (do not build yet): the layout rethink — "terminal without
its own toggle view: terminal + toggleable side artifact viewer + some sort of
observer view for running agents and rooms." Also parked: the room-agent CHECKLIST
primitive (deliberate design session first — prototype as prompt-level convention in
real rooms before any engine mechanism) and the resolve inversion (human answers,
engine writes the receipt post; the prefilled-syntax composer is rejected).

---

## Addendum 2026-07-26 — slice 1a SHIPPED: the terminal-centered frame

The ⌘T two-faces model is dead; helm is one permanent surface. Left: the
observe/steer sidebar (engine header, projects, Live/History rooms). Center: the
terminal workspace, always visible, min 480pt. Right: ONE shared dock — a selected
room's detail wins it, else the open artifact, else it collapses; Esc deselects.
Sticky dock width via @AppStorage (idealWidth restore; HSplitView won't persist).
⌘T freed (reserved), ⌘J reserved for terminal-maximize; the Resolve-prefill died.

---

## Addendum 2026-07-27 — concept rev 2: slice 1a's successor, and four corrections

A high-fidelity concept now exists for what comes after slice 1a (artifact
`4efa3d35-a936-4953-913a-bcdc7c208489`). Its shape: **the project becomes the
operating context** (switch it and terminals, operator, rooms and artifacts all
swap); an **operator chat** takes the center as home; the **terminal becomes a
strip** with ⌘J to full height; **rooms unfold to their participants** and ↑/↓/→/←
walks them. The context bar carries fleet truth at home and git truth inside a room.

Rev 1 of that concept was drawn before the naming audit and guessed at engine state.
Four corrections, each checked against code rather than remembered — this is the record.

### 1. Vocabulary — the mock now speaks the glossary

Rev 1 said workstream / main agent / driver / fleet bar throughout. `GLOSSARY.md`
(2026-07-26) retires all of them and names helm UI copy explicitly. Renamed in the
concept and in its own CSS class names: room, operator, context bar, participants
(never bare "session"). `History` survives as helm's tab label — the glossary
sanctions that one spelling — but the rooms behind it are *archived* everywhere else.
Residual, flagged not fixed: the CLI's `kild agent ls` / `--agent` in the persona
sense, already parked by the glossary for "when next touching the CLI".

### 2. The operator chat is a REVERSAL, and now carries its argument

Addendum 2026-07-24 (2) killed this exact surface on purpose: *"a bespoke operator
chat would freeze one harness into the UI"* — the operator rotates by inference
economics. Reviving it without answering that would just be forgetting. The answer,
in three parts:

- **It is not a harness, it is a view onto a kild session.** helm posts prompts and
  renders a transcript; the model comes from the config `models` catalog, resolved
  engine-side. helm encodes no harness, no model, no persona — rotation stays where
  it already happens.
- **The fear was partly right, and we accept the limit.** kild sessions are pi
  processes. The chat hosts pi on any model; it cannot host Claude Code or codex.
  So the terminal is not a fallback for when the chat fails — it is the permanent
  home for every harness kild does not wrap. Two operators, one surface.
- **It is additive, never load-bearing.** Spawn no session and helm is precisely
  slice 1. That is Deliver-Signals holding: the engine keeps the contract, the
  cockpit stays the courtesy surface.

### 3. Slice 2 AMENDS AGENTS.md rather than violating it

The boundary today reads "The terminal is the center of attention — never hidden,
never swapped, never below comfort width." Slice 1 is compliant (terminal still the
center's tenant); slice 2 is not. The rule changes in the same PR as the layout:

> The terminal is never more than one keystroke from full height — never hidden
> behind navigation, never swapped for another tenant, never below comfort width
> while it holds the center. ⌘J is the guarantee.

"Esc is never intercepted globally (TUIs own it)" survives untouched.

### 4. The engine is already done — the missing client is helm's

Rev 1 called the chat "the biggest new piece" and assumed new engine work. Wrong:

- `POST /api/sessions {operator:true}` spawns it with room-control tools
  (`KILD_OPERATOR=1`); `forkFrom` exists for frozen-context forks.
- `POST /api/sessions/:id/prompt`, `POST /api/sessions/:id/stop`, `GET /api/sessions`,
  `GET /api/sessions/:id/transcript` — send, teardown, list, backfill.
- **Live streaming already exists.** Every WS connection subscribes to
  `sessionManager` (`engine/src/server.ts:660`) and receives `{session, event}`;
  `UiEvent` carries `text` deltas, `tool_start`/`tool_end`, `model`, `stats`, the
  `pi_session` resume handle, `agent_end`.

The real gap is helm-side and **slice 1 needs it too**: `EngineClient` has no session
methods, and helm has **no WS client at all** — `RootView` polls `/api/rooms/live` on
a 5s `Timer`. A 5s poll cannot render a transcript that types. So slice 2's cost is
helm's first streaming client plus delta assembly; slice 1 collects the same benefit
because room state stops being five seconds stale.

**Verify, do not assume:** whether a room's report wakes the operator session that
*opened* it. The delegate-nudge exists for a room lead; the opener path is asserted by
Deliver-Signals but unconfirmed in code. If missing, that is the one engine addition
slice 2 needs.

### Build order

**Slice 1 — the observer half**: project-context frame, rooms column with participant
expansion + collisions, context bar, artifact dock, ⌘J terminal center. Terminal stays
the center's tenant, so AGENTS.md is untouched and the whole slice is dogfoodable. Its
one piece of real weight: **project stops being a filter and becomes the operating
context** — per-project ptys inside TerminalManager, per-project store resolution,
per-project selection state. Everything else is rendering over data `/api/rooms/live`
already returns.

**Slice 2 — the kild chat**, planned after a week of real use. Carries the AGENTS.md
amendment and helm's first WS client.

Also to fix in slice 1: `SidebarColumn.swift` renders open decisions as a numbered
`⚠ n` label — a numbered pill, which both the concept ("counts live only in the
context bar") and AGENTS.md ("attention is a state of existing elements, never an
added element") forbid.

---

## Addendum 2026-07-27 (2) — concept rev 3: helm is an ADE, and the chat leaves the center

Owner framing that reshapes the concept: **helm replaces one-IDE-per-desktop**. Today
that is N macOS Spaces, one IDE each, switched with ⌃1/2/3. helm becomes the ADE —
one window holding every project context at once. Two sentences from that session
drove rev 3: projects should switch like Spaces, and *"mostly I will likely run my
operator in the terminal."*

### Move 1 — projects to a top bar, on Mission Control's keys

A sidebar list reads as *a filter inside this world*; a top bar reads as *which world
am I in*. The metaphor picks the position, and it frees the whole left column for
rooms now that they unfold into participants. So: a project strip above the three
columns, each tab carrying the same amber attention state its rooms carry.

Keys mirror Mission Control rather than inventing — `⌃1–9` direct, `⌃←/→` adjacent.
**They collide by design**: while Mission Control holds those bindings the keystrokes
never reach any app, so they must be handed over in System Settings → Keyboard →
Shortcuts. That trade is only right because helm subsumes the reason those desktops
existed. Cost to accept: intercepting `⌃1–9` takes Ctrl+2…8 from the terminal, where
they are legacy control codes (rarely pressed deliberately, but the same family of
concern as "Esc is never intercepted globally").

### Move 2 — the operator chat becomes the dock's third tenant (WITHDRAWS rev 2's Correction 3)

Rev 2 argued the chat back from the dead and gave it the center. The owner's actual
habit undoes the premise. Not a deletion — a relocation:

- Select a room → dock shows room detail *(shipped in 1a)*
- Select a participant → dock shows its transcript
- **Select the operator → dock shows the conversation + composer**
- Select nothing → the artifact, else the dock collapses
- **Center is always the terminal**

Left column is what you observe, dock is its detail, center is your hands. One rule,
no exceptions. Consequences:

- **The AGENTS.md amendment is withdrawn.** The terminal is never demoted, so the
  boundary as written ("never hidden, never swapped, never below comfort width")
  survives untouched. Rev 2's Correction 3 is dead.
- **The chat needs no new layout** — it reuses the dock mechanism 1a already shipped.
- **⌘J gets a real job**: fill the window (hide sidebar + dock), not "swell over the chat".
- **The composer addresses the dock's tenant** — post to room, or message the operator.
- **Slice 2 becomes deferrable indefinitely**: "add a tenant," not a re-layout.

Recorded plainly: the 2026-07-24 (2) decision that killed the operator strip looks
more right than rev 2 gave it credit for. Rev 2's three-part argument stays on file as
the case for building the chat *at all* — it no longer buys the center.

**Operator spawn: never auto.** Decided. An idle pi process per project is surprise
token spend. Until you start one, the left column's top row is a dashed
"start operator" affordance.

### Move 3 — what per-project context actually costs

"Everything swaps" sounds like serializing a workspace. Sorted by what each thing is,
only one tier is state:

1. **Live resources — kept running.** ptys and their ghostty NSViews, per project. A
   build in project 1 keeps building while you are in project 2. Terminals belong to a
   project and never move between them; a project gets its first shell lazily on first
   visit. No auto-eviction — the ceiling is N projects × M terminals, stated not
   engineered around.
2. **Engine-owned — nothing to do.** Rooms, participants, git state, cost, the
   operator session all live in kild and keep running regardless; helm holds an id and
   a filter. The single `/api/rooms/live` poll already returns every project's rooms,
   so cross-project attention is free to compute.
3. **UI state — the only save/restore.** Selection, expanded rooms, Live/History tab,
   dock tenant, open artifact, terminal tab, ⌘J, composer drafts. One struct per
   project, ~15 fields.

**Does NOT swap:** window size, sidebar/dock widths, font size, theme. Body
preferences, not context — per-project dock width would make every switch feel like
the window twitching.

**The risk:** `TerminalManager` is a `.shared` singleton with a flat session list and
`TerminalWorkspace` binds `manager.selected`. Per-project lists reshape that selection
model, in the one component whose header warns about lifecycle. Mitigation: the
mechanism already exists — tab switching dismantles the SwiftUI representable via
`.id(session.id)` while the manager keeps owning the NSView. Parking a project is the
same move at a coarser grain.

**Known gap, deliberately unbuilt:** artifact scroll position across a switch. A
webview per project is unbounded memory; restoring scroll costs a mermaid re-render
and a beat of jank. Ship without it.

### Build order (supersedes the rev 2 split)

**Slice 1 — the ADE frame.** Project top bar + per-project contexts; observe column
rebuilt around rooms expanding to participants, with collisions and amber attention;
context bar; artifact dock unchanged. Terminal keeps the center, so AGENTS.md is
untouched and every byte renders engine data that already exists. The weight is the
contexts, not the rendering.

**Slice 2 — the operator tenant**, whenever the terminal stops being enough: a third
dock tenant, explicit start, helm's first WS client.

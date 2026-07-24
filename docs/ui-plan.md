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

That sketch is the north star. It's conversation-first, and it makes the **main agent
session** (a resident fleet driver) a first-class surface — you talk to it up top, and the
rooms it opens appear below as workstreams you can arrow into.

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
agent-operators). But when a human *is* watching, the cockpit's job is to make the fleet
legible at a glance — which is exactly the Fog-lifting the engine can't do for a human.

---

## Where the UI is today (~2,900 lines, Tauri + SvelteKit)

A working room-centric cockpit exists:
- **One left sidebar** stacking projects → rooms → worktrees in a single 240px column.
- **Room view**: the shared room log + the focused participant's "working detail" in a
  50/50 split; participant chips; on-the-fly invite.
- **Composer**, **Topbar** (focused agent's name, model, branch chip, ctx%/tokens/cost).
- Modals for new project / new room.
- Live WS reconcile with the engine; archived-room history.

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
3. **No fleet tier / no "main session."** Detached fleet drivers and plain sessions are
   invisible (nothing consumes `/api/sessions`). The "main agent session at the top" concept
   from the sketch doesn't exist yet.
4. **Zero keyboard navigation.** The up/down-arrow-into-each-session idea — not there.
5. **Hardcoded, stale model list** in the spawn modal (`claude-sonnet-4-6`, `gpt-5.5`…),
   disconnected from the config **model catalog** the fleet actually uses.
6. **Participant transcripts are ephemeral** (in-memory). Join a CLI/pi-opened room late —
   which is now the normal flow — and "working detail" is blank forever.

## What's design-shit right now (opinionated)

- **Sidebar IA**: projects, rooms, worktrees as three flat lists in one column. Rooms are
  the core object but read like anonymous log lines (`@agent` / "3 agents" + project name) —
  no goal/title, no last-activity, no needs-attention. Worktrees as a sibling section is
  redundant (a worktree is a workstream's *property*).
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
│ projects │  MAIN SESSION (the fleet driver — persistent chat)  │  ← top strip
│  (thin)  ├──────────────────┬──────────────────────────────────┤
│          │ workstreams tree │   selected session's view        │
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
- **Workstreams tree** — rooms under the active project, each expandable to its **sessions
  (participants)** with model + running/idle/**needs-attention** dot. **↑/↓ walks every
  session across rooms; →/← expands/collapses.** The engine already streams every
  participant's transcript — the UI just needs focus-follows-selection.
- **Main agent session on top** — a resident **fleet-driver session** (sol, holding the
  fleet room-control tools). The engine already supports spawning exactly that
  (`POST /api/sessions {fleet:true}`). The top strip is your standing chat with it; rooms it
  opens appear in the tree below. This unifies "human drives" and "agent drives" into one
  surface — the VISION.md sentence, made real, and consistent with Deliver-Signals (the
  driver is an agent; the human just watches/steers it).
- **Right rail** — the observability payoff per selected workstream: git/collision/cost/
  spawn-tree.
- **Attention model** — rooms sort needs-you-first (lead→@human / blocker / idle-finished),
  with a badge. Close moves behind a confirm, away from the row.

---

## Build order (minimal slices, independent where possible)

1. **Observability into the UI** — types + right rail + roster models + idle state. Data is
   already on `/api/rooms/live`; pure rendering; immediate payoff. *(Slice 1 — partly done,
   see In flight.)*
2. **Sidebar → workstreams tree + keyboard nav** — the ↑/↓ session walker; restructures the
   IA around workstreams. *(Slice 2.)*
3. **Attention states + safe close** — needs-you badges, idle-finished first-class,
   confirm-to-close.
4. **Model catalog into the spawn modal** — kill the hardcoded list; serve the config
   catalog (a tiny engine endpoint, or reuse what the pi extension reads).
5. **Main driver session strip** — the resident sol chat. Biggest new concept, most
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

**Not yet wired:** the Sidebar workstreams *tree*, the keyboard nav, and the right rail that
renders the git/collision data. So the data model is ~ready but nothing new is shown yet —
`app/` won't cleanly build as a finished feature until Slice 1's rendering + Slice 2 land.
It's uncommitted, so it blocks nothing.

---

## Open questions (decide before Slice 5)

- **Main driver session**: auto-spawn with the cockpit, or explicit "start driver"? Per
  project or one global driver? What model (sol by default)?
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

Per project: `.kild/LOG.md` is a ready-made workstream history browser (one entry per
closed room: goal, outcome, decisions, resume handles) and `.kild/MEMORY.md` /
`direction.md` are the project's brain. A read-only "memory" tab on the project view
renders all three. Engine-side it may deserve a tiny `GET /api/projects/:name/memory`
rather than the Tauri shell reading files directly.

### Open questions — recommendations

- **Main driver**: explicit "start driver" (auto-spawn = surprise token spend), one per
  project, model from the config catalog (first entry as default) — never hardcoded.
- **Attention priority**: the structural ranking above; open decisions outrank everything.
- **Drive vs watch**: watch + steer. Every UI action is an operator action that already
  exists engine-side (open/post/invite/close/resolve). Courtesy surface, never contract —
  unchanged, now with better data.

---

## Addendum 2026-07-24 (2) — transcript gems + two direction changes

Source: Archon feedback session 2026-07-23 (Rasmus/Matt/John). Two decisions supersede
parts of the plan above; the gems justify a new slice.

### Decision: the main view is a TERMINAL, not a driver strip (supersedes slice 5)

The "main agent session strip" (engine-spawned resident fleet driver) is dead. Instead:
an embedded real terminal (xterm.js + Tauri pty) where you open pi / Claude Code / codex
— whichever harness has credits — and that harness drives kild via its existing
skill/extension/CLI. The rest of the cockpit is the view + control into kild itself.
Toggle terminal view ⇄ kild view.

Why: the driver rotates by inference economics (Claude Code → Opus+kild → pi someday);
a bespoke driver chat would freeze one harness into the UI. This kills slice 5's open
questions (auto-spawn? which model? per project?) entirely.

Rules that keep it clean:
- **Host the terminal, never scrape or inject.** The pty is opaque to the UI; everything
  the driver does materializes through the engine (rooms/posts/WS), which is what the
  kild view renders. Handing context to the driver = explicit copy-to-clipboard, never
  send-keys. (Inverting firstmate: hosting is safe, scraping was the tax.)
- The pty lives outside the webview lifecycle — view toggles never kill the driver.

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

1–2. Observability rendering + workstreams tree/keyboard nav (in flight, unchanged).
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
  read-only artifact split beside them ("driver in the terminal, plan beside it":
  ⌘O opens a file, .md renders formatted, re-renders on external change). The kild
  view is unchanged. Shortcuts: ⌘T face toggle, ⌘N new terminal, ⌘1–⌘9 select tab,
  ⌘O open artifact.

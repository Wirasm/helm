# The bench architecture

**A plan, not the tree.** The operator approved this shape on 2026-09-25. It describes where
helm and `benchd` are going, not what exists; `AGENTS.md` describes the tree. The milestone
sequence that builds it is `bench-roadmap.md`, and work on any of it starts when the operator
names a milestone.

## What we are building

One shared workspace for one human and many agents. **helm is the window**: a keyboard-first,
tiling surface where either side can show the other anything. **benchd is the engine**: it owns
everything that must outlive a window and everything agents act on. Agents keep their own
harnesses (Claude Code, codex, pi) and their own tools (Playwright, git, shells). The bench adds
only what they lack: a shared place to see, show, talk and hand over.

It should feel like Hyprland: instant, keyboard-driven, everything scriptable through one
command surface, with tools that appear when you want them and go away when you don't.

## Seven primitives, and nothing else

Everything else is built from these. A feature that needs an eighth primitive is a design smell
to stop at.

| # | Primitive | What it is | Owner |
|---|---|---|---|
| 1 | **Session** | A process in a pty: an agent TUI or a shell. Has a handle. | benchd |
| 2 | **Surface** | Anything a pane can show, named by a typed source: `term:<session>`, `file:<path>` (markdown, HTML, board), `browser:<tab>`. New kinds plug in at the edge. | benchd provides bytes; helm renders |
| 3 | **Layout** | Workspaces → columns → slots → panes (today's shape), plus **drawers**. A pane is a view of one surface. | benchd (the bench document) |
| 4 | **Verb** | Every change goes through one door: `bench <verb>`. helm's own keystrokes are verbs too. Each verb carries who asked. | benchd executes; helm renders the result |
| 5 | **Event** | An append-only log of what happened. helm follows it to redraw, agents to wait. | benchd (`events.jsonl`) |
| 6 | **Record** | Files: mail, artifacts, notes, state, config. `ls` and `cat` read all of it. Syncs across machines as a folder. | the filesystem |
| 7 | **Rule** | Config at the edges: keybinds → verbs, placement rules, surface kinds, postures, in TOML files reloaded live. Compositions of verbs live in justfiles. | the operator |

Attention ("blocked", "done") is not a primitive; it is a projection of events. The shared
browser is not one either: it is a helper benchd supervises, plus a surface kind.

## The focus rule

**Focus moves only when the operator acted, or when an agent's verb says the operator asked
for it.**

- An agent verb without `--asked` lands in the background: a new tab, a drawer badge, a column
  to the right. This is today's `offer`, made the default for every agent verb.
- `--asked` lets an agent bring something forward or focus it. "Only when asked" is a prompt
  rule in the skill, not a check: the daemon cannot know what the operator said, and pretending
  it can is the trap #320 measured (a socket wake and the operator typing look identical from
  outside).
- There is **no typing lock**. `--asked` and the skill's rule are the whole mechanism.

## The Hyprland feel, mapped onto the primitives

| Hyprland | The bench | Built from |
|---|---|---|
| Workspaces | Workspaces (one per project), switched by key | Layout |
| Tiling with keyboard ops | Columns and slots. Swap and move panes and columns **by key, by drag and drop, and by agent verb**, all through one `move` verb. #290 shipped keyboard move. | Layout + Verb |
| Special workspace / scratchpad | **Drawers**: named overlays toggled with one key. Browser, queue (attention and mail), notes, board, logs. Content persists while hidden. | Layout + Surface |
| Window rules | **Placement rules file**: "agent spawns → new column right", "browser → browser drawer", "artifacts from X → background tab" | Rule |
| `hyprctl dispatch` | `bench <verb>`: open, show, move, focus, spawn, mail, get | Verb |
| `hyprctl` event socket | `bench events --follow` / `bench watch <handle>` | Event |
| `bind = key, dispatcher` | Keymap file: key → verb, or key → `just <recipe>`. helm translates keys; benchd executes. | Rule + Verb |
| `exec` scripts, user macros | **justfiles**: named compositions of `bench` verbs, run by the operator, bound to keys, or run by agents. `daemon/justfile` already works this way as the executable spec. | Rule + Verb |
| Groups (tabbed windows) | Slots with tabs | Layout |

**Drawers are where tools come up when needed.** An agent that wants to show you something puts
it in a drawer and badges it. You open the drawer when you choose. It never rearranges the bench
you are working in.

## Who owns what

**benchd (Rust)**: sessions and their ptys; the bench document (layout, drawers, focus state);
verb execution and placement rules; the event log; mail and wakes; the attention projection;
supervised helpers (the shared browser); the record root. It never draws and never reads a key.

**helm (Swift)**: renders the bench document; turns keys and mouse into verbs; hosts surface
views (terminal, document, board, browser); marks and notes on documents; the status bar. It
holds no placement logic, no persistence of its own, and no agent-facing API.

**Agents**: their own harness and tools, plus `bench` (CLI and skill). Playwright for the
browser. Nothing agent-specific is built into helm or benchd.

## The Swift target shape

helm on 2026-09-25 is 23.9k lines in `Sources/Helm` (Canvas 6.2k, Workbench 3.8k, Archon 2.5k,
Terminals 2.1k, Chat 1.7k, App 1.4k, Spool 1.3k, Board 1.1k, the rest under 1k each), plus 6.1k
in HelmWire and tools. The target is a small core plus surface plugins:

```
Core      BenchClient   one socket: subscribe to document + events, send verbs
          LayoutView    renders columns/slots/panes/drawers from the document
          Keymap        key → verb, from the rules file
          StatusBar     projections: attention, limits, isolation, build
Surfaces  protocol SurfaceKind { source type; makeView(source) -> view }
          Terminal (Ghostty, fed from benchd) · Document (md/html + marks) ·
          Board · Browser · Rail (Archon, worktrees) as a drawer surface
```

What leaves Swift, and at which milestone:

- **Spool** (1.3k) and the six `tools/*.swift` spool scripts: deleted, replaced by `bench`
  verbs (M3).
- **Placement and mutation logic** in `Workbench` (most of 3.8k): moved to benchd. Swift keeps a
  render-only value (M4).
- **Persistence** (the UserDefaults half of Workspaces): moved to benchd's record (M4).
- **Board/presence and `BenchSnapshot`** (1.1k): become projections of the event log (M1/M4).
- **Mail** hooks and the pi watcher: reduced to sensors (M2 finish).
- **Chat** (1.7k, a transcript poller measured 8.8s behind): leaves the core. If wanted again,
  it is a document surface rendered over the transcript logs. Not a priority.
- **Terminal pty ownership**: moved to benchd (M5b). Swift keeps the Ghostty surface, fed
  through the attach relay.

Rough target: helm core under ~5k lines, with Canvas as the largest plugin, because
collaboration surfaces are the product. Every move follows the roadmap's working discipline:
the new path runs in parallel, the old code is unwired only when proven, red then green.

## The terminal stack

The requirement: **one source of truth per terminal**, held by benchd, which agents can read
(text, cursor, scrollback), write to and follow live, and which the operator sees at full
native quality. Sessions survive helm restarting. **Every pane is a benchd session, including
the operator's own shells**, so "an agent can look at my terminal" is a verb, not a feature.

Research (2026-09-25, primary sources):

- **Ghostty** has no read-side IPC (its AppleScript support, since 1.3, is write-only and a
  preview). Embedded libghostty always owns its own pty today. Upstream PR #14277 adds a non-pty
  backend (tmux panes as native surfaces) and was unmerged as of 2026-09-20. **libghostty-vt**
  (Ghostty's VT engine, headless, C API) exists, with community Rust bindings (`libghostty-vt`
  0.2.1).
- **kitty** remote control (`get-text`, `send-text`, `ls`) is snapshot-only, and kitty is not
  embeddable. Streaming a pane to other readers is **zellij's** feature: `zellij action
  subscribe` streams pane content as JSON, and its web client is multiplayer.
- **WezTerm** has the right mux model, but `wezterm-term` is not on crates.io and there has been
  no release in 2.5 years. **tmux** control mode works but has no stable contract. Both ruled
  out.
- **Rust VT engines**: `alacritty_terminal` (0.26, team-maintained, real damage tracking) is the
  safe choice; `libghostty-vt` has the highest fidelity and is young.
- **Native renderers**: SwiftTerm accepts external bytes but draws on the CPU with CoreText, a
  visible step down from Ghostty. A custom Metal painter is months of work. Feeding libghostty's
  renderer from outside has no upstream path yet.

**Checked 2026-09-25 (versions and roadmaps; detail in #359):**

- **libghostty-vt is pre-1.0 at both layers**, Ghostty's C API and the Rust bindings. Its
  `Terminal` is **never `Send`**: upstream closed that as won't-fix because the C API makes
  no cross-thread guarantee. So each session's VT state lives on one pinned OS thread for its
  lifetime. Plan for a vendored pin, not tracking crates.io.
- **`alacritty_terminal`** (0.26.0) stays the fallback. Nearly every minor release breaks
  something, so each bump is a small migration.
- **Replace `portable-pty`.** Nothing has been published in 19 months, and its reason to
  exist, Windows ConPTY, is dead weight here. Use `rustix` `openpty` with our own spawn. This
  can land before the VT spike.
- **No upstream Ghostty backend without a pty yet.** Ghostty 1.4 targets scripting and a true
  tmux control mode; #14277 is tmux-specific. Keep the relay. helm's vendored Ghostty 1.3.1 is
  still the latest tag.

Decision:

- **benchd holds the truth**: its own ptys (`rustix` `openpty` plus our own spawn, replacing
  the `portable-pty` in `bench-session` today), the raw byte log it already keeps, and **a VT
  engine per session**, each on its own pinned thread, for structured reads: `bench get screen`,
  `bench send`, `bench watch --screen` (a zellij-style subscribe). A short spike under real
  agent output picks the engine. `libghostty-vt` is preferred because it is the same engine as
  helm's renderer, so what an agent reads is what the operator sees; `alacritty_terminal` is the
  fallback if the bindings are too raw.
- **helm keeps Ghostty's renderer**, fed from benchd by running the attach relay inside a
  Ghostty surface. That already works (M5a, `bench attach`). The operator keeps full Ghostty
  quality, and one byte stream feeds both parsers. If upstream ever ships a non-pty backend
  (none is on its roadmap as of 1.4), the inner relay pty goes away and nothing else changes.
- **No custom painter.** M5b becomes: every helm terminal pane is a benchd session shown through
  the relay; restore-on-restart is benchd's; `bench get/send/watch` works on any pane.
- **Not adopted**: zellij, tmux or WezTerm as the session server. Each would take ownership of
  the truth away from benchd. zellij's `subscribe` and web client are the reference design for
  `watch` and for a later browser or phone view.

## Decided 2026-09-25

1. **Layout**: keep columns → slots → panes, plus drawers. Moving and swapping panes and columns
   works by key, by drag and drop, and by agent verb, all through one `move` verb.
2. **Chat face**: not a core feature. If wanted, a document surface over the transcript logs.
   Not a priority.
3. **No typing lock.** `--asked` and the skill's prompt rule are the whole focus mechanism.
4. **Rules format**: TOML. Compositions of verbs go in justfiles.
5. **Terminals**: benchd owns every pty and runs a VT engine per session; helm keeps Ghostty's
   renderer through the attach relay. No custom painter.
6. **Cross-machine means files**: the record syncs as a folder over Tailscale. No socket
   exposure and no peering protocol until files prove not to be enough.
7. **Not a browser driver**: the bench supervises one shared browser and shows it; agents drive
   it with their own Playwright.

# helm

The native macOS cockpit: a terminal at the centre, hosting CLI agents and rendering what
they write. This is helm's canonical vocabulary. `../GLOSSARY.md` holds the cross-repo terms
helm shares with kild and prp; where the two overlap, this file wins for helm.

## Language

### People and processes

**operator**:
The human at the keyboard. helm has exactly one.
_Avoid_: user, driver, main agent

**agent**:
A CLI agent already in use — Claude Code, pi, codex. helm hosts one in a terminal it owns
and renders what it writes; it never builds or hosts an agent of its own.
_Avoid_: assistant, bot, participant

**terminal**:
helm's shell — one libghostty surface with its own pty.
_Avoid_: terminal session, tab, console

### What helm has open

**workspace**:
A folder the operator has opened. Identity is its path; there is no registration and no
unique-name constraint. **Nothing sits above it** — a workspace is helm's top level.
_Avoid_: project, folder, repo, Archon's "workspace" (which means a repo — see **project**)

**workbench**:
The pane arrangement inside a workspace: columns of vertical stacks, each slot tabbed.
One per workspace. benchd holds it (the **bench document**); helm draws it and changes it only
by sending verbs. If a workspace ever holds several they are numbered, never named.
_Avoid_: layout, named layout, window manager, tab group

**slot**:
One tabbed cell of a workbench column. A slot holds panes and knows which of them is on
screen; a column is a vertical stack of slots. Selection is a property of a slot, never of
the app — several slots are visible at once, each with its own selected pane.
_Avoid_: cell, tab group, split

**pane**:
A workbench tenant. Three kinds: **terminal**, **canvas** and **browser pane**.
_Avoid_: view, widget, dock

**surface kind**:
What one kind of pane is, in one place (`SurfaceKind`): how its live object is made, drawn, shown
on a tab and let go. Every live pane object of every kind is kept in one **surface registry**, keyed
by pane id. A new kind of pane is a new conformance and one registration; nothing in the bench asks
what kind a pane is.
_Avoid_: pane type (in code), plugin, renderer

**name**:
What a pane is called on its slot's tab strip, and **who called it that**. benchd *derives* one
for a pane it opens for an agent it spawned; an agent *chooses* one with `bench name`, and may
replace a derived one freely but not a chosen one unless it says `--rename`, the operator asked. A pane with
no name falls back to what it can say about itself — a terminal to its shell's **title**, a
canvas to the file or host it is showing. Persisted on the pane, so it survives a relaunch.
_Avoid_: title (that word is the shell's, one level down — OSC 0/2 — and outranked by a name),
label, caption, tab name

**visible**:
Whether the operator can actually see a pane — it is its slot's selection, and its
workspace is the active one. Distinct from **selected**, which is slot-local and answers
for several panes at once. Bells, finished-command marks and desktop notifications are all
rules about what is *visible*, which is why `TerminalSession` carries `isVisible` rather
than a copy of anyone's selection.
_Avoid_: selected, active, focused

**focused**:
The one pane the keyboard belongs to: the focused slot's selected pane, `Workbench.focusedPane`.
Exactly one in the whole bench, where **visible** is one per slot and **selected** is one per
slot's tabs. It is what a command acts on and where typing goes — and the two must not come
apart, which is #96: a bench where three panes were visible, one was focused, and the
keyboard was held by none of them.
_Avoid_: active, current, selected, first responder (that word is AppKit's, one level down)

**canvas**:
The pane type that renders a file — markdown or HTML — and accepts annotation on it. Modular by
source; extendable to further formats. A web page is not a canvas: it is a tab of the shared
browser, in the **browser pane**. A **markdown** canvas also
has a writing face the operator enters deliberately; **read is the default**, and helm stops
saving rather than overwrite a file somebody else wrote since it last looked.
_Avoid_: artifact pane, webview, browser, draw-on pane

**browser pane**:
The pane type that shows the **shared browser** — the one Chrome benchd runs per bench root
(`bench browser start`), which agents drive with Playwright and the operator uses by hand. helm
neither starts nor automates it: the pane reads benchd's `browser/endpoint.json`, draws the tab
it follows over CDP, and forwards mouse, keys and the clipboard. One per bench, and it lives in
the `browser` **drawer**: ⌘⇧B shows or hides it, and an agent's `bench open browser` or a
⌘-clicked http link (a new tab) badges the drawer without opening it. Not a canvas: a canvas
renders a file in helm's own webview.
_Avoid_: webview, canvas, embedded browser

**drawer**:
A named holder of tabbed panes, shown over the bench instead of in it (#356). One per name for
the whole bench document, beside the workspaces rather than inside one, and at most one open at a
time. Opening or closing one never re-lays-out the bench under it. It holds panes, so anything a
pane can show can live in one, and it exists only while it holds at least one. Which drawer is open
is the operator's focus: an agent never opens one without *asked*; its pane lands in the drawer
and **badges** it. Lives in benchd's document; helm draws the open one over the bench
(`Sources/Helm/Drawers/`), where and how wide from `[drawer.<name>]` in the keymap file.
_Avoid_: panel, sidebar, rail (the rail is helm's own and is not a drawer), scratchpad, overlay

**sessions drawer**:
The drawer on the left (⌘⇧S) listing every agent session in the active workspace, as benchd's
`sessions/all` answers it (#384): running first, then newest. A row opens with the one action
benchd computed for it — show its pane, attach, resume or read its transcript — and a finished
row can be dismissed. helm adds no rule of its own about which sessions belong.
_Avoid_: agent list, sidebar, session browser

**badge**:
A drawer's mark that something arrived in it the operator has not seen: an agent put a pane
there or offered one it already held. Opening the drawer clears it.
_Avoid_: notification, unread count, dot (that is how helm will draw it, not what it is)

### What helm looks like

**board**:
The workspace bar's answer to *which workspace has an agent that needs you* — one mark per
workspace tab, from the agent registry alone. Three renderings and not two: nothing where there is
no agent, a quiet dot where every agent is working, an attention dot where one has stopped.
helm holds **no state of its own** here — the registry file's lifecycle is the mark's lifecycle,
so nothing acknowledges, decays or expires, and there is nothing to clear. It never hides,
including on the workspace being looked at.
_Avoid_: **drawable board** (a different thing — see below), status bar, badge, notification
centre, calling the attention dot an "unread"

**drawable board**:
A **canvas** an agent authors as labelled shapes and the operator draws on by hand, their marks
coming back as named records. It is a kind of canvas and nothing structural: helm has no board
pane, and nothing in the **board** above knows it exists. Owned by the `helm-board` skill, which is
where the colliding word comes from — no Swift in `Sources/Helm/Board/` is about this at all.
_Avoid_: board unqualified (that word is the workspace marks), whiteboard, sketch pane, diagram

**rail**:
The remembered, default-hidden strip to the right of the workbench: **somewhere to start work
that is not your current work**. It holds the Archon and Worktrees tenants. Archon renders a
title, a field, a send button, one line per **running run**, and a count per other status.
Worktrees is one collapsed line until requested, then becomes a per-repository ledger of every
record from `git worktree list --porcelain`: branch and owner kind, local disk size and directory
activity, and reachability from the resolved remote default branch. It does not poll. Cleanup is
confirmed and owner-routed through `archon complete` or guarded `git worktree remove`, never force.
Nothing opens from the rail; run detail is read in Archon's own web UI. It is not another place
panes can dock, a file tree, or a cross-repository inventory.
_Avoid_: sidebar, pane dock, monitor rail, calling it a run list

**Worktrees**:
The rail's on-demand, per-repository ledger of linked Git worktrees. Git porcelain is the shared
discovery source for hand-made and Archon-owned trees. “Merged” means Git reachability from an
explicit resolved remote default branch, not pull-request state; an unknown base is never
cleanable. helm does not read Archon's database or HTTP API, call global `archon isolation
cleanup`, inventory unrelated repositories, or automatically force deletion.
_Avoid_: worktree pane, worktree sidebar, file tree, disk dashboard

**running run**:
The one status the rail gives a line to, with a subline naming the **stage** it is on. Every
other status — including `paused` — is history or a gate, and collapses to a count.
_Avoid_: active run (the word the rail used when `paused` had a row too), open run, live run

**stage**:
One node of a workflow run, named the way Archon names it — `parse-request`, `implement`,
`validate`. What the rail's subline says, because it is the thing that advances.
_Avoid_: step (that word is `current_step_name`'s, which Archon never populates for a DAG),
node (right in Archon's own model, but the rail shows one at a time and not the fold)

**palette**:
helm's one table of colours, as values (`Palette.helm`). There is exactly one, and every
surface spends it — the chrome as SwiftUI `Color`s, the terminal as ghostty config lines.
Before it there were three unrelated sources and the app did not read as one thing.
_Avoid_: theme (that word is ghostty's, one level down), colour scheme, style

**token**:
One entry in the palette — a *role*, named for the job it does and carrying a value for each
appearance. `surface`, `textMuted`, `accent`. Never named after the colour it happens to be
in one appearance, because it is a different colour in the other.
_Avoid_: swatch, variable, named colour

**chrome**:
Everything that is not the work: the workspace bar, a slot's tab strip, a canvas toolbar,
the status bar. It recedes.
_Avoid_: UI, frame, decoration

**glass**:
The one translucent material the whole window is made of — a behind-window vibrancy plane
that the desktop shows faintly through. Chrome sits on it tinted up a step; the terminal
grid sits on it too, made translucent by ghostty's own `background-opacity` rather than by
anything SwiftUI can reach. Two weights of one material, never two materials.
_Avoid_: blur, vibrancy, frosted (as a noun), calling the chrome's weight "the" glass

**hint**:
One line the status bar draws saying a key and what it does. Rendered from the key table in
force (`Keymap.table`), whose rows carry the word as well as the key, so neither is written down
twice; which rows get one is a choice, what they are bound to is not.
_Avoid_: tooltip, help, cheatsheet

**keymap file**:
`<bench root>/rules/keymap.toml`, the operator's keys. Its rows overlay helm's built-in table
(`KeyBindings.all`): a row replaces the built-in keys with its chord, `unbind` removes one, and a
file that does not parse changes nothing. helm reads it; nothing writes it. It sits beside benchd's
`placement.toml`, which benchd reads and helm does not.
_Avoid_: keybindings.json, config, shortcuts file

**bench justfile**:
`<bench root>/rules/justfile`, the operator's recipes: compositions of `bench` verbs (#356). A
key bound to `action = "just"` or an agent's `bench just <recipe>` asks benchd to run one
(`just/run`), at the active workspace, logged as `just/started` and `just/finished`. Run for
the operator, its verbs are his and may move his focus; run for an agent, they are the agent's.
Not a workspace's own justfile.
_Avoid_: macro, script, recipe file

### What agents produce

**artifact**:
A file an agent wrote into a store. Build products are not artifacts.
_Avoid_: document, output, report

**store**:
A directory holding one project's artifacts. Two roots today — `~/.prp/<key>/` and
`~/.archon/workspaces/<owner>/<repo>/` — and more are expected. The roots key differently:
prp by the repo's git common dir, Archon by its GitHub owner and repo.
_Avoid_: vault, library

**project**:
The repo a store belongs to. **prp's and Archon's word, not helm's own** — helm says it only
where it surfaces their artifacts, and it names no level in helm's own structure. All of a
repo's worktrees resolve to one project.
_Avoid_: using it for anything structural in helm; kild's registry sense, which helm dropped
with the kild layer

**workstream**:
prp's unit of parallel work — one agent, one branch, one PR. Borrowed as-is when talking
about `prp-orchestrate`. The sild glossary's retirement of this word was kild-scoped and
does not bind helm.
_Avoid_: room, fleet

### How an agent reaches helm

**bench verb**:
What an agent drives the bench with: `bench open|split|show|focus|move|name|close|spawn|get`, a
request to benchd over its socket, the same door the operator's keys go through (M3). It lands in
the background unless it says `--asked`, the operator asked. It replaced the **spool**, a directory
of request files helm watched, which retired with its six scripts.
_Avoid_: spool, request file, helm API

**bench snapshot**:
A versioned, atomically replaced JSON report at `~/.helm/bench/snapshot.json` that lets an
agent read mounted and parked workspaces, workbench arrangement, pane/session identity,
visibility, focus and freshness without a display or request round trip. It is a projection,
not persistence and never a control channel; the **bench verbs** are how an agent acts.
_Avoid_: bench API, layout database, restore file

**canvas state latch**:
A versioned JSON file beside a canvas — `<artifact>.state.json` — holding what that page last
said about **itself**, written latest-wins and read by the agent on its **next turn**. A latch,
not an interrupt: nothing wakes a session, starts a turn or spends a credit, and a page still
cannot say anything into a live prompt. The **sidecar** is its opposite number and stays
separate — that one is the operator's own notes, appended and never rewritten, where this one
is machine state and every earlier value is noise.
_Avoid_: callback, event, message (nothing is delivered — the agent reads a file); telemetry

**teardown**:
Closing a pane with `bench close` — the inverse of a spawn, and it stops at the **pane**. benchd
refuses an agent's close of a terminal unless it says `--force`, and the pane the operator is
working in unless it says `--asked`. Worktrees and branches are not teardown's:
that is #141's rail, which confirms with the operator and never deletes unmerged work.
_Avoid_: kill, destroy, cleanup (cleanup is the worktree rail's word)

### Not levels in helm

**worktree**:
Git's word, unmodified. Agents create and discard worktrees to isolate their own work; the
operator rarely opens one. A worktree opened as a workspace is a workspace of **equal
standing** to its main checkout — helm models no parent above either, and no worktree level
beneath a workspace.
_Avoid_: treating a worktree as a child of a workspace, or as what a workbench is bound to

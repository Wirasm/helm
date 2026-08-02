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
One per workspace. If a workspace ever holds several they are numbered, never named.
_Avoid_: layout, named layout, window manager, tab group

**slot**:
One tabbed cell of a workbench column. A slot holds panes and knows which of them is on
screen; a column is a vertical stack of slots. Selection is a property of a slot, never of
the app — several slots are visible at once, each with its own selected pane.
_Avoid_: cell, tab group, split

**pane**:
A workbench tenant. Two types: **terminal** and **canvas**.
_Avoid_: view, widget, dock

**face**:
Which of a terminal pane's two presentations is drawn — the terminal, or the agent's
writing over it. A property of the pane, so two terminals side by side can show different
ones; a canvas has none.
_Avoid_: mode, view, tab

**visible**:
Whether the operator can actually see a pane — it is its slot's selection, and its
workspace is the active one. Distinct from **selected**, which is slot-local and answers
for several panes at once. Bells, finished-command marks and desktop notifications are all
rules about what is *visible*, which is why `TerminalSession` carries `isVisible` rather
than a copy of anyone's selection.
_Avoid_: selected, active, focused

**canvas**:
The pane type that renders content — a markdown file, an HTML file, or a URL — and accepts
annotation on it. Modular by source; extendable to further formats.
_Avoid_: artifact pane, webview, browser, draw-on pane

### What helm looks like

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
the status bar. It is translucent — the desktop shows faintly through it — and it recedes.
The terminal is never chrome and is never translucent.
_Avoid_: UI, frame, decoration

**hint**:
One line the status bar draws saying a key and what it does. Rendered from `Shortcut.all`,
never written down twice; which commands get one is a choice, what they are bound to is not.
_Avoid_: tooltip, help, cheatsheet

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

### Not levels in helm

**worktree**:
Git's word, unmodified. Agents create and discard worktrees to isolate their own work; the
operator rarely opens one. A worktree opened as a workspace is a workspace of **equal
standing** to its main checkout — helm models no parent above either, and no worktree level
beneath a workspace.
_Avoid_: treating a worktree as a child of a workspace, or as what a workbench is bound to

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

**focused**:
The one pane the keyboard belongs to: the focused slot's selected pane, `Workbench.focusedPane`.
Exactly one in the whole bench, where **visible** is one per slot and **selected** is one per
slot's tabs. It is what a command acts on and where typing goes — and the two must not come
apart, which is #96: a bench where three panes were visible, one was focused, and the
keyboard was held by none of them.
_Avoid_: active, current, selected, first responder (that word is AppKit's, one level down)

**canvas**:
The pane type that renders content — a markdown file, an HTML file, or a URL — and accepts
annotation on it. Modular by source; extendable to further formats.
_Avoid_: artifact pane, webview, browser, draw-on pane

### What helm looks like

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

### How an agent reaches helm

**spool**:
A directory helm watches — `~/.helm/spool` — where a **request** to start an agent appears as
a file. helm's one push channel, and the only one that works with the screen locked, headless
or over ssh: everything else needs a display, a focused window and an Accessibility grant.
Under `HELM_DEFAULTS_SUITE=<name>` it moves to `~/.helm/spool-<name>` with the rest of that
instance's state.
_Avoid_: queue, inbox (the mailbox is the inbox), API, control channel

**request**:
One file in the spool, of one **kind**: a `spawn` (`{id, cwd, command, args, prompt}`), a
`capture` (`{id, kind, path, window}`) or a `close` (`{id, kind, terminal, force}`). Acted on
**at most once** — claimed by rename into `claimed/`, which is a graveyard and never re-read,
so a restart mid-spawn cannot double-open. Only the agents in `SpoolPolicy.allowedCommands` may
be named, and only by a spawn.
_Avoid_: job, task, command (the `command` is a field of it)

**teardown**:
Closing a pane through the spool — the inverse of a spawn, and it stops at the **pane**. helm
refuses a pane with live work unless the request says `force`, and refuses the pane the
operator is working in whatever the request says. Worktrees and branches are not teardown's:
that is #141's rail, which confirms with the operator and never deletes unmerged work.
_Avoid_: kill, destroy, cleanup (cleanup is the worktree rail's word)

**result**:
What helm writes back at `spool/results/<id>.json`, and the half that makes the spool a
protocol rather than a shout. Carries the terminal id, the pid, the session id and the
**handle** — so the caller's next move, addressing the agent it just started, needs no lookup
of its own. Written twice on success: `started` at once, `ready` when the agent claims a
mailbox. Every request gets one, refusals included.
_Avoid_: response, ack, receipt

### Not levels in helm

**worktree**:
Git's word, unmodified. Agents create and discard worktrees to isolate their own work; the
operator rarely opens one. A worktree opened as a workspace is a workspace of **equal
standing** to its main checkout — helm models no parent above either, and no worktree level
beneath a workspace.
_Avoid_: treating a worktree as a child of a workspace, or as what a workbench is bound to

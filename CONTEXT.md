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

**pane**:
A workbench tenant. Two types: **terminal** and **canvas**.
_Avoid_: view, widget, dock

**canvas**:
The pane type that renders content — a markdown file, an HTML file, or a URL — and accepts
annotation on it. Modular by source; extendable to further formats.
_Avoid_: artifact pane, webview, browser, draw-on pane

> **The code has not caught up, deliberately.** The type is still `ArtifactPane` and the dock
> that hosts it is `CanvasDock`. The rename touches the same files the canvas work reshapes,
> so it lands with that work rather than ahead of it — this is a known gap, not a violation to
> fix in passing. Say **canvas** in prose either way.

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

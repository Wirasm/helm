# helm — the idea

im the user its built for me and the way i work

Entry point for planning. Nothing here is decided.

helm is the surface you work in, full screen, all day. Native macOS. It hosts terminals,
renders what agents produce, and gives quick access to the actions you run often. The
intelligence lives in agent skills and Archon workflows

**"Agent" always means a CLI agent — Claude Code, pi, or another you already run.** helm
does not build, host, or define an agent of its own. It runs the CLI in a terminal it owns,
reads what that CLI writes, and gives it surfaces to write to. Anything that looks like
helm having an agent is helm rendering someone else's.

## Layout

One column for the early route: the **workbench**, under the workspace bar. A **right bar**
arrives last, with Archon.

- **Workbench** — the middle. Where panes are organised. **Panes live here, full stop** — the
  bar is not a second place one can dock.
- **Right bar** — not actions. A **rail of ambient things you monitor and act on**, and its
  one tenant is Archon's run list. Toggleable, remembered, **default hidden**. Nothing else
  earned a slot, and Archon is ranked last, so helm has nothing either side of the bench for
  the whole early route.

The **artifact browser is a ⌘O popover**, not a bar tenant — a picker you summon, not
something you watch. Copying an artifact's path is a context menu on its row, and the path is
the tilde-absolute `~/.prp/<key>/plans/foo.md` (the form prp's own README invokes).

There is **no file tree**. A tree is navigation, which is not what the rail is for, and
`git status` already answers the one job it had — checking the agent put files where it
should. It stays a deferral, not a rejection: dogfooding decides.

There is **no left bar**. Every job proposed for one is taken — workspaces by the workspace
bar, terminals by the tab strip, the file tree by the right bar — so it leaves the early
route rather than being designed. Ideas exist for later (a list of open worktrees to open a
terminal in, running Archon workflows), but they wait on dogfooding to prove a need.

## Primitives

- **Workspace** — the folder you're working in.
- **Workbench** — the bench panes are arranged on. Multiple terminals, chats, canvas,
  markdown. Lego panes, close to a window manager.
- **Terminal**
- **Markdown editor**
- **Integrated webview** — agents can control it, you can draw on it, and it sends context
  back to the agent.
- **Agent canvas** — renders agent reports, fully manipulable by agents. e.g. _"build a task
  tracking tool in the canvas"_ → the agent builds it and it renders as something
  interactive.

## Terminal ↔ chat toggle

A toggle between the terminal view and a chat view of the same session.

The agent CLIs in use (pi, Claude Code) already write full logs to the filesystem. helm
overlays a UI on those logs: a readable chat with proper markdown formatting, a chat box,
and a calmer view for focus.

## Archon surface

Not an API client — the CLI's `--json` and the file tree. Two pieces:

- A **run list** in the rail — background `--detach` runs with key metadata. Clicking one
  opens a curated node view as a **bench pane**, not inside the rail.
- A **launcher** summoned from a `+` at the head of that list: a form composing the CLI
  command from workflow, input, and flags. Ships without a model control.

## Sizing

Optimise for exactly three aspects, nothing else:

- laptop (MacBook 14)
- full screen on a wide curved monitor
- half screen wide

No mobile. No other targets.

## Where intelligence lives

Agent skills and Archon workflows. That includes teaching agents how to use the canvas.
helm renders and routes; it does not decide.

## Open

- Whether a left bar ever earns its width, once helm has been lived in.
- Whether a file tree ever earns a job the diff does not already do.

## Facts that already hold

Not decisions — things that are true today and shape what is cheap.

- helm hosts its terminals via GhosttyKit and owns the surface and its pty. **Reading** is a
  function call — `ghostty_surface_read_text` (what is rendered), `ghostty_surface_tty_name`,
  `ghostty_surface_foreground_pid`. **Writing is not.** Measured 2026-07-31
  (`~/.prp/helm-3ec376fc/reports/nice-view-spike-client.md`):
  - `ghostty_surface_write_buffer` paints the emulator screen and the pty **never sees it**.
    It is the host-managed backend's *output* path, used only by `InMemoryTerminalSession`.
    Against the `.exec` backend it fails by looking like it worked. An earlier version of
    this file called it "write into a session" — that was wrong.
  - `ghostty_surface_text` — the wrapper's only public write API — lands printable text but
    silently sanitizes control bytes: ESC arrives as a space, CR is dropped.
  - `ghostty_surface_binding_action("text:…")` delivers raw bytes byte-exact, and is the only
    route that works. It is module-internal, so writing into a hosted terminal **starts by
    extending the vendored wrapper patch**, not by calling an API helm already has.
- Claude Code and pi both write full session transcripts to disk, so a chat view is a
  renderer over files rather than an integration — but the grain is coarse. Measured
  2026-07-31 (`~/.prp/helm-3ec376fc/reports/nice-view-spike-reader.md`): Claude Code writes
  one **content block** per record, written whole when the block ends; pi writes one record
  per **model response**. There is no intra-block state on disk, so a typewriter-style live
  view is impossible from files — and a turn's first record lands a median 8.8s after the
  request. Neither format redacts secrets.
- **A from-disk view cannot show the operator the question they are being asked.** An agent
  blocked on an interactive prompt writes *nothing*. Captured live: the agent thought,
  produced 1,962 characters of prose and raised a question — none of it reached disk until
  the operator answered **2m35s later**, then all four records flushed at once. Whatever the
  chat view turns out to be, it cannot be *only* a file renderer: the moments that most
  demand attention are exactly the moments the file is silent. Reading the rendered surface
  (`ghostty_surface_read_text`) is the only source that has them.
- helm already has working markdown and HTML rendering (`ArtifactPane`, `ArtifactHTML`,
  `ArtifactWebViews`, `PostMarkdown`, `MarkdownTheme`, `ArtifactBrowser`) and the terminal
  stack (`TerminalManager`, `TerminalStrip`, `TerminalCapabilities`, `GhosttyConfig`).
- The kild layer was removed on `chore/drop-kild-layer`; what remains is workspaces,
  terminals, artifact rendering, and the app shell.
- GhosttyKit ships iOS and Catalyst slices alongside macOS.

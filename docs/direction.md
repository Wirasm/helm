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

Three columns: **left bar · workbench · right bar**.

- **Left bar** — not specified yet.
- **Workbench** — the middle. Where panes are organised.
- **Right bar** — quick access. Think of it as **actions**. Artifact browser lives here.
  Possibly a file tree, not a priority. Archon actions go here too.

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

## Archon panel

An openable panel. Roughly: a workflow picker, an input field, a model picker — shaped to
whatever the API actually offers.

Plus some Archon controls in the right bar as actions.

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

- What goes in the left bar.
- What else belongs in the right bar beyond the artifact browser and Archon actions.
- Whether the file tree earns a place.
- Exact shape of the Archon panel, pending the API.

## Facts that already hold

Not decisions — things that are true today and shape what is cheap.

- helm hosts its terminals via GhosttyKit and owns the surface and its pty. The vendored
  API exposes `ghostty_surface_text` and `ghostty_surface_write_buffer` (write into a
  session), `ghostty_surface_read_text` (read what is rendered), `ghostty_surface_tty_name`
  and `ghostty_surface_foreground_pid`. So writing into a hosted terminal is a function
  call, not an injection hack.
- Claude Code and pi both write full session transcripts to disk, so a chat view is a
  renderer over files rather than an integration.
- helm already has working markdown and HTML rendering (`ArtifactPane`, `ArtifactHTML`,
  `ArtifactWebViews`, `PostMarkdown`, `MarkdownTheme`, `ArtifactBrowser`) and the terminal
  stack (`TerminalManager`, `TerminalStrip`, `TerminalCapabilities`, `GhosttyConfig`).
- The kild layer was removed on `chore/drop-kild-layer`; what remains is workspaces,
  terminals, artifact rendering, and the app shell.
- GhosttyKit ships iOS and Catalyst slices alongside macOS.

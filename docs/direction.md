# helm — the idea

im the user its built for me and the way i work

Entry point for planning — the shape, not the sequence.

**The build order is settled**: `~/.prp/helm-3ec376fc/plans/helm-build-order.plan.md`, the
destination of wayfinder map [#17](https://github.com/Wirasm/helm/issues/17). It ranks every
surface below, names what each one proves, and puts the **switch-over line after position 1**
— restoring workspaces and terminals across a restart, which is the only thing keeping helm
from being the daily driver. Read it before planning any surface here.

**Where helm is heading** is the bench: a daemon (`benchd`) that owns sessions, the
layout and the record, with helm as the window. The approved shape is
`docs/future-planning/bench-architecture.md` and the sequence is `bench-roadmap.md` beside it.
Both are plans, not the tree.

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
- **Right bar** — a rail of **quick actions on things that are not your current work**.
  Operating Archon, operating on worktrees, and whatever earns a line later. Toggleable,
  remembered, **default hidden**; Archon is ranked last, so helm has nothing either side of
  the bench for the whole early route.

  This first said *not actions — ambient things you monitor*, with Archon's run list as its
  one tenant. Dogfooding said otherwise: what you actually want from the run list is to
  **start, approve and cancel** runs, and the second tenant to arrive is worktree cleanup,
  which is nothing but a verb. Monitoring is what the rail shows you *so that* you can act.

  **A tenant is one collapsed line that expands** — `Worktrees`, `Archon` — not a panel. That
  shape is what makes a tenant nearly free when it is not in use, and it is why the rail can
  hold things consulted rarely without earning its keep every minute. Build the rail that way
  first; a run list that merely sits on the right is not one.

The **artifact browser is a ⌘O popover**, not a bar tenant — a picker you summon, not
something you watch. Copying an artifact's path is a context menu on its row, and the path is
the tilde-absolute `~/.prp/<key>/plans/foo.md` (the form prp's own README invokes).

There is **no file tree**. A tree is navigation, which is not what the rail is for, and
`git status` already answers the one job it had — checking the agent put files where it
should. It stays a deferral, not a rejection: dogfooding decides.

There is **no left bar**. Every job proposed for one is taken — workspaces by the workspace
bar, terminals by the tab strip, the file tree by the right bar — so it leaves the early
route rather than being designed. The two ideas parked here for later — *a list of open
worktrees, running Archon workflows* — waited on dogfooding to prove a need, and it did:
both are now tenants of the **right** rail, which is the shape that fits them.

## Primitives

- **Workspace** — the folder you're working in.
- **Workbench** — the bench panes are arranged on. **Depth-2**: N columns, each a vertical
  stack, each slot tabbed. A real window manager, but not a general tree — every arrangement
  worth having is columns-of-stacks, and depth-2 is a strict subset of the tree so nothing is
  foreclosed.
- **Pane** — a workbench tenant. **Three types.**
  - **Terminal** — a libghostty surface and its pty. The chat face that used to draw an
    agent's transcript over it (⌘T) was removed on the operator's ruling (#375).
  - **Canvas** — renders a markdown file or an HTML file, and accepts annotation on
    it. Modular by source, extendable to further formats. This is `ArtifactPane` promoted,
    not new work — and the promotion has shipped, so it is `CanvasView` / `CanvasModel` now.
  - **Browser** — a view onto the shared browser benchd runs (#350). A ⌘-clicked http link
    opens there as a new tab (#376); the URL canvas that used to take it was removed.

  A third type was built for Archon and then removed with the rail it served. The argument for
  it is not preserved here: the operator reads run detail in Archon's own web UI, so there is
  nothing left for a run pane to render, and a short list is easier to defend than a longer
  one with a footnote.

The canvas is **one** primitive, not three: the integrated webview, the draw-on pane and the
agent canvas merged into it. And the agent **receives and navigates, never drives** — full
browser control already exists as `playwright-cli` and helm would ship a worse copy. The
agent's route in is to write a self-contained file and print a link you ⌘-click: **offer, not
push**. A pane appearing unbidden is helm rearranging the bench on the agent's word.

## Archon surface

Not an API client — the `archon` CLI's `--json`, captured through a temporary file. No HTTP
and no direct SQLite reads. **Input first**, which is the correction #40 made after the
list-first version was built and run: the same workflow is started over and over, so that has
to cost zero clicks, and reading a finished run is rare and belongs on the bench.

**Minimal on purpose, and that is the second correction.** The full version of this was built,
used, and cut back — *"too much bloat, I want to start simple"*. What is gone: run panes,
finished-run rows, Archon's `approve`/`reject`/`abandon` verbs, helm's own dismissal filter,
and the liveness mark. Run detail is read in Archon's own web UI, which is better at it than
helm will ever be.

The rail renders five things, and nothing else:

- A **prompt field**, always present. Type, press Enter, the workflow runs detached.
- A **send button** doing the same thing for the mouse.
- **Settings** behind an icon, holding what a launch composes — the workflow and how it
  isolates. Built to grow as the CLI does; ships without a model control.
- **One line per running run**, with a subline naming the **stage** it is on and changing as
  its nodes advance.
- **One collapsed count per other status**, `paused` included. Clicking one does nothing: it
  is a number, not a way in.
- **It carries Archon's brand and Archon's status colours, and keeps them apart.** The brand is
  the console's duotone — magenta → violet → teal, painted on the title and the send button,
  because that gradient *is* the mark. Status is deliberately not brand: a running run is
  Archon's electric blue, a failure its red, a completed run the brand teal. All of it is
  governed tokens held at helm's contrast floors, never hex in a view, and never Archon's
  charcoal chrome wholesale: *distinctly Archon's*, not *foreign*.
- **Worktrees.** A second, collapsed tenant reads `git worktree list --porcelain` only when
  expanded, then shows every record with owner kind, local disk size, directory activity and
  reachability from the repository's resolved remote default branch. That reachability is Git's
  “merged”, not pull-request state; if the base cannot be resolved the row stays unknown and is
  not cleanable. Confirmed cleanup routes through `archon complete <branch>` for recognised
  Archon branches and guarded `git worktree remove <path>` for the rest, without force flags.
  Clean All serialises those same visible, eligible routes. It never uses Archon's global cleanup,
  reads Archon's database or HTTP API, inventories unrelated repositories, or becomes a file tree.

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

Both wait on the same trigger — **living in helm** — which the build order now makes
reachable, since switch-over is one change away rather than a whole route away.

- Whether a left bar ever earns its width. Its last candidate is a worktree picker, and it
  has to beat the test a column tenant must pass: **monitored or acted on, not navigated**.
- Whether a file tree ever earns a job the diff does not already do. Declined by *both*
  columns on that same test.

Everything else the map left dim is recorded in
[#17](https://github.com/Wirasm/helm/issues/17)'s *Not yet specified*.

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
    route that works. **It is public and helm can call it today** —
    `AppTerminalView.performBindingAction`, in a file whose header reads *"public wrappers
    around `TerminalSurface` write paths so hosts can inject bytes into the pty without
    reaching for internal API."* An earlier version of this file called it module-internal
    and said writing **starts by extending the vendored wrapper patch** — that was wrong, and
    it over-generalised the spike's real finding: what is module-internal is the `surface`
    *property* and the read signals (`mouse_captured` and friends), which is what the spike
    actually needed its patch for. Writing into a hosted terminal costs **no vendor patch**.
    The guard on that write is a registry file read (`status == idle`), not a surface signal,
    so it needs no patch either.
- Claude Code and pi both write full session transcripts to disk, so a transcript view is a
  renderer over files rather than an integration — but the grain is coarse. Measured
  2026-07-31 (`~/.prp/helm-3ec376fc/reports/nice-view-spike-reader.md`): Claude Code writes
  one **content block** per record, written whole when the block ends; pi writes one record
  per **model response**. There is no intra-block state on disk, so a typewriter-style live
  view is impossible from files — and a turn's first record lands a median 8.8s after the
  request. Neither format redacts secrets.
- **A from-disk view cannot show the operator the question they are being asked.** An agent
  blocked on an interactive prompt writes *nothing*. Captured live: the agent thought,
  produced 1,962 characters of prose and raised a question — none of it reached disk until
  the operator answered **2m35s later**, then all four records flushed at once. Any transcript
  view (the chat face was one, until #375 removed it) cannot be *only* a file renderer: the
  moments that most demand attention are exactly the moments the file is silent. Reading the rendered surface
  (`ghostty_surface_read_text`) is the only source that has them.
- **Remote control is the agent's, not the terminal's — so it costs helm nothing.** Claude
  Code publishes a per-session `bridgeSessionId` in `~/.claude/sessions/<pid>.json`, which is
  how the operator drives a session from his phone. It is a property of the agent process,
  independent of which terminal hosts it, so helm neither buys nor breaks it. The one real
  consequence: if helm dies the agent dies with it and the bridge goes too — which is why
  helm-build work stays outside helm, an accepted tradeoff rather than a problem to solve.
- **Terminals survive a restart** — position 1 of the build order, and the switch-over line.
  A workspace's tab row is rebuilt on first visit from the ids persisted for it, under those
  same ids so the saved selection still resolves. Shells come back **empty**: helm does not
  re-run the agent, because it attaches to agents and never owns their launch. A `cls --resume`
  brings one back, and it republishes to the session registry, so nothing downstream depends on
  helm having started it. *(Until 2026-08-01 the loader filtered saved ids against the ids live
  in the process, which at launch is none — so the persistence was neutered by its own loader
  and a relaunch cost every terminal in every workspace.)*
- helm already has working markdown and HTML rendering (`ArtifactPane`, `ArtifactHTML`,
  `ArtifactWebViews`, `ArtifactBrowser`) and the terminal stack (`TerminalSession`,
  `TerminalManager`, `TerminalStrip`, `GhosttyConfig`).
- **The source is sliced vertically by feature** — `App/`, `Workspaces/`, `Terminals/`,
  `Canvas/`, `Artifacts/`, `Shared/` — with each vertical owning its own commands, and `App/`
  reduced to composition. Keyboard shortcuts are a table of values (`KeyBindings`, overlaid by the
  operator's `rules/keymap.toml`) read by the event monitor, the menu and the status bar's hints. See `AGENTS.md` for the patterns.
- The kild layer was removed on `chore/drop-kild-layer`; what remains is workspaces,
  terminals, artifact rendering, and the app shell.
- GhosttyKit ships iOS and Catalyst slices alongside macOS.

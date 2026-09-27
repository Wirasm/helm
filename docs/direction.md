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
  Operating on worktrees, and whatever earns a line later. Archon was its first tenant and moved
  to a drawer along the bottom (#382), where a row of stage dots per run has the width it needs. Toggleable,
  remembered, **default hidden**; Archon is ranked last, so helm has nothing either side of
  the bench for the whole early route.

  This first said *not actions — ambient things you monitor*, with Archon's run list as its
  one tenant. Dogfooding said otherwise: what you actually want from the run list is to
  **start, approve and cancel** runs, and the second tenant to arrive is worktree cleanup,
  which is nothing but a verb. Monitoring is what the rail shows you *so that* you can act.

  **A tenant is one collapsed line that expands** — `Worktrees` — not a panel. That
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
the worktrees are a tenant of the **right** rail, and Archon's runs are a drawer (#382).

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

A drawer along the bottom of the window (⌘⇧R, #382), over the bench like every drawer. Not an API
client — the `archon` CLI's `--json`, captured through a temporary file. No HTTP and no direct
SQLite reads. **Input first** (#40): the same workflow is started over and over, so the composer
is always at the drawer's foot, ⌥↑/⌥↓ picks the workflow, and Enter runs it detached.

**What it shows**, for the active workspace's project: runs **waiting on you** (paused at a gate),
**running** runs, and **finished** runs not yet cleared — each a row with **a dot per stage**,
filling in as the run advances, where it is or how it ended, and what it was asked to do. The
selected row expands to its stage names and durations. It reads `workflow runs --json`, plus one
`workflow status --json --verbose` while anything is live, every two seconds while the drawer is
open, and nothing while it is hidden. A gate is therefore only seen with the drawer open, which the
operator accepted for now (2026-09-27).

**What it does, from the keyboard**: answer a gate (`a`, `x`, or `1-9` for a decision the workflow
declared), resume (`r`), cancel (`c c`), follow the run's log in a terminal pane (`l`), open a
finished run's pull request (Enter) or clear it (⌫). Depth beyond that — transcripts, the graph —
is Archon's own web UI.

**What it still does not have**, because the rail it replaced was cut back as *"too much bloat"*:
no counts or tallies, no liveness word, no run pane. **Agents do not use it**: Archon's CLI
(`workflow status/get/wait --json`) is their view. benchd and `bench` know only the drawer's
surface kind, `archon`, as they know `sessions`: an agent can put nothing in it and read nothing
from it.

- **It is painted as Archon's panel.** The drawer's ground, raised surfaces and rules are Archon's
  console surfaces (dark from Archon's own tokens; light values chosen by helm, since Archon has no
  light appearance). The brand is the console's duotone — magenta → violet → teal — on the title.
  Status is deliberately not brand: a running stage is Archon's electric blue, a stage waiting on
  you amber, a failure its red, a done stage the brand teal. All of it is governed tokens held at
  helm's contrast floors, never hex in a view.
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
  operator's `rules/keymap.toml`) read by the event monitor, the menu and the key pop-up.
  See `AGENTS.md` for the patterns.
- The kild layer was removed on `chore/drop-kild-layer`; what remains is workspaces,
  terminals, artifact rendering, and the app shell.
- GhosttyKit ships iOS and Catalyst slices alongside macOS.

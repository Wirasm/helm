# libghostty spike

**Goal**: prove that a SwiftUI app can host a real libghostty terminal surface running
the user's shell, surviving the ⌘T view toggle without losing the session. This is the
quality bar of the whole app (the terminal is the main view), so it's proven FIRST —
before helm gets a GitHub repo or any more features.

**Exit criteria**
1. `TerminalPane` renders a GhosttyKit surface running `$SHELL`; typing works; a TUI
   (run `pi` in it) renders correctly.
2. ⌘T to the kild view and back: the shell session is intact (pty owned outside the
   view lifecycle).
3. Window resize reflows the terminal correctly.

**Non-goals for the spike**: tabs/splits, config UI, selection/clipboard polish,
app bundling/entitlements (that's the XcodeGen graduation, after).

## Build steps — REVISED 2026-07-24: no zig required

Research (see links below) killed the zig bottleneck: libghostty was extracted as a
standalone module during Ghostty's 1.3 cycle, and prebuilt universal
GhosttyKit.xcframework artifacts now exist — official CI releases on tip, plus
`libghostty-spm` packaging it as an SPM binary target. Order of preference:

1. **libghostty-spm** (Lakr233) — add as an SPM dependency; zero toolchain. PIN the
   exact version (the API is explicitly unstable between releases).
2. **Official tip xcframework release** from ghostty CI — vendor the artifact,
   `.binaryTarget(path:)`, pin the release tag here.
3. **Build from source** (`scripts/build-ghosttykit.sh`, requires zig) — LAST resort
   only, e.g. to bisect an upstream bug.
4. Implement `TerminalPane` against the C API: app create → NSView-backed surface →
   keyboard/mouse/resize plumbing. References: the official libghostty C API docs
   (mintlify) and Ghostty's own macOS wrapper (`macos/Sources/Ghostty/` upstream).
   Record the pinned version here when it works.

## EMBED LANDED — 2026-07-24 (path 1: libghostty-spm)

**Pinned**: `libghostty-spm` **exact 1.3.1** (tag of 2026-07-17; its binary target is
`storage.1.3.1` → GhosttyKit.xcframework, checksum-locked in the package). Transitive:
MSDisplayLink ≥ 2.1.0. Bump only deliberately: re-read the wrapper sources at the new
tag first — the C API AND the Swift wrapper both churn.

**What shipped vs hand-rolled** — far more shipped than expected. The package is not
headers-only: its `GhosttyTerminal` product is a full Swift wrapper —
`TerminalController` (ghostty_init / config render+load / ghostty_app_new),
`AppTerminalView` (Metal-layer NSView with keyboard, IME/NSTextInputClient, mouse,
selection, scroll, resize, focus, display-link ticking), delegate protocols for
title/close/bell/pwd/OSC events, and an `.exec` backend flag that maps to
`GHOSTTY_SURFACE_IO_BACKEND_EXEC` (real pty). We hand-rolled only the helm side
(`Sources/Helm/GhosttyTerminal.swift`):

- `GhosttyTerminal` (app-level singleton): owns the `TerminalController` and ONE
  long-lived `AppTerminalView`; sinks title/close/lifecycle delegate events into
  published status. The pty survives view unmount because the surface belongs to the
  NSView's coordinator and the singleton retains the NSView forever — upstream only
  tears a surface down on view dealloc, never on window detach
  (`AppTerminalView+Lifecycle.swift: viewDidMoveToWindow` reuses an existing surface).
- `GhosttyHostView` (NSViewRepresentable): mounts the shared NSView, never creates
  one — so SwiftUI dismantle can't kill the session. Forwards nothing by hand:
  resize/keyboard/mouse live in the wrapper's NSView. Only focus (first responder
  follows the ⌘T toggle) and render occlusion (`setSurfaceVisible`) are ours.
- Shell: `command` left unset on purpose → libghostty runs the passwd shell
  (= `$SHELL`) as a **login shell**; cwd = home.

**API landmines found**
- **No terminfo in the xcframework** (headers + static lib only). Ghostty's default
  `TERM=xterm-ghostty` breaks TUIs on machines without Ghostty.app installed. Fixed
  with config `term = xterm-256color`. Same gap: no bundled shell-integration
  resources, so OSC-133 prompt features (jumpToPrompt, command-finished events) are
  inert unless the user's shell emits markers itself.
- **Do NOT use the wrapper's `TerminalSurfaceView`/`TerminalViewState` SwiftUI path**
  for the main pane: its representable creates the NSView per mount, so a SwiftUI
  dismantle deallocs the view → coordinator → surface → pty dies. App-level NSView
  ownership (above) is the survival mechanism.
- The surface spawns lazily on first attach to a window with nonzero size; there is
  no public "surface failed" callback — a hard init failure surfaces only as
  `TerminalController.lastConfigurationIssue` (checked at startup) or a close event.
- `ghostty_surface_config_s` (headers win over the mintlify docs): `backend`,
  `command`, `working_directory`, `env_vars`/`env_var_count`, `initial_input`,
  `wait_after_command` — the docs lag this struct.
- Naming: our class is intentionally also called `GhosttyTerminal` (same as the
  imported module). Fine as long as nothing needs `GhosttyTerminal.X`
  module-qualified lookup; rename ours if that ever bites.

**Exit criteria status**
- [x] `swift build` green (hard gate)
- [x] Non-GUI smoke: ghostty_init + config load + app create in `Tests/HelmTests`
      (`swift test`) — no window needed
- [ ] HUMAN: pane shows a live shell; typing works; `pi` (TUI) renders correctly
- [ ] HUMAN: ⌘T to kild view and back — session intact (run `sleep 99`, toggle,
      confirm it's still running; also quit-and-reopen is expected to LOSE the
      session, that's fine)
- [ ] HUMAN: window resize reflows the terminal (no smearing, grid follows)
- [ ] HUMAN: shell exit (⌃D) flips the pane to the "shell exited" fallback

## Known risks (why this is a spike)

- **libghostty API churn** — the remaining real risk: upstream says the embedding API
  is not yet stabilized and may change significantly between releases. Mitigation: pin
  the package/artifact version, keep our wrapper thin, copy patterns from Ghostty's own
  macOS wrapper rather than inventing. (`libghostty-vt`, a stable parsing-only lib, is
  planned upstream — not sufficient for us; we need the full surface.)
- **SPM + xcframework quirks**: binaryTarget with a locally-built xcframework usually
  works; if SPM fights, the fallback is graduating to XcodeGen early (project.yml is
  ~30 lines) — xcodegen is already installed.
- **Event plumbing volume**: keyboard/IME/mouse/scroll forwarding is the bulk of the
  embed work. The reference wrapper is the map; budget most of the spike here.

Links: mitchellh.com/writing/libghostty-is-coming · github.com/Lakr233/libghostty-spm ·
mintlify.wiki/ghostty-org/ghostty/api/overview · github.com/Uzaaft/awesome-libghostty

## Fallbacks — two layers (survey 2026-07-24)

Full landscape assessed: libghostty, alacritty_terminal (the Zed path), SwiftTerm,
xterm.js-in-WKWebView, termwiz, rio/sugarloaf, libvterm. Ranking for a Swift host:

- **Tactical** (libghostty embed fights the one-day timebox): **SwiftTerm** behind the
  same `TerminalPane` interface — pure Swift, ships in La Terminal/Secure ShellFish/
  CodeEdit, weakest rendering but a working pane in hours. Keeps helm moving.
- **Strategic** (libghostty API churn becomes intolerable over months): the **Zed
  path** — `alacritty_terminal` as the engine (PTY + VTE + grid, the most
  battle-tested embeddable core) with our own Swift/Metal renderer, mirroring Zed's
  three layers (engine / view / element). Rust FFI + hand-built rendering: the most
  durable independence, the biggest build. Not a quick swap; a deliberate rebuild.
- Rejected for a Swift host: termwiz (self-described "wild sweeping changes", no PTY),
  rio/sugarloaf (built for Rust/web hosts), libvterm (dated surface, renderer+PTY on
  us), xterm.js island (WKWebView input quirks, violates the native decision) — kept
  only as an emergency stopgap.

The `TerminalPane` interface (spawn shell, feed input, resize, survive toggle) is the
seam that keeps all of these swappable.

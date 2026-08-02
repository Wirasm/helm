# libghostty spike

**Goal**: prove that a SwiftUI app can host a real libghostty terminal surface running
the user's shell, surviving the ⌘T view toggle without losing the session. This is the
quality bar of the whole app (the terminal is the main view), so it's proven FIRST —
before helm gets a GitHub repo or any more features.

**Exit criteria — ALL VERIFIED by the human, 2026-07-24**
1. ✅ `TerminalPane` renders a GhosttyKit surface running `$SHELL`; typing works; TUIs
   render correctly.
2. ✅ ⌘T to another view and back: session intact. (Fix required: ghostty's view
   swallows ⌘-key equivalents — an app-level NSEvent local monitor now owns ⌘T.)
3. ✅ Window resize reflows the terminal correctly.
4. ✅ Shell exit flips the pane to the fallback instead of a dead surface.

The spike is COMPLETE. Pinned: libghostty-spm 1.3.1 (revision b0930320).

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

> **Names, as of 2026-08-01.** This section is the spike's own record and its helm-side
> names are a snapshot, not current paths. `GhosttyTerminal.swift` no longer exists: the
> app-level singleton owning ONE view became `Terminals/TerminalSession.swift` (one per
> tab) plus `Terminals/TerminalManager.swift` (owner of the sessions and the single shared
> `TerminalController`), and `GhosttyHostView` is `Terminals/GhosttyHostView.swift`. ⌘T no
> longer toggles anything — it is deliberately unbound. **The lifecycle contract and the
> API landmines below are unchanged and still load-bearing**; only the file names moved.
>
> **Except focus, which is a different mechanism now (#96, 2026-08-03).** The bullet below
> says first responder follows the ⌘T toggle, out of `GhosttyHostView`. It does not: the
> claim comes from AppKit's `viewDidMoveToWindow` on a helm-owned subclass,
> `FocusClaimingTerminalView`, gated on an intent flag the bench pushes down from
> `Workbench.focusedPane`. The old shape — a `DispatchQueue.main.async` hop out of
> `updateNSView` — dropped the claim silently whenever the view had no window yet, which is
> a terminal that accepts no keystrokes at all. See `Terminals/GhosttyHostView.swift`.

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
  inert unless the user's shell emits markers itself. (Closed later: helm now
  VENDORS ghostty's shell-integration script tree at the embed's exact source
  commit — docs/VENDORED.md — and points GHOSTTY_RESOURCES_DIR at the bundled
  copy first; an installed Ghostty.app's resources are only the fallback, which
  additionally provides named themes. See GhosttyConfig.swift.)
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
- [ ] HUMAN: ⌘T to another view and back — session intact (run `sleep 99`, toggle,
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

## Kitty graphics verification (harness only — no feature code)

Whether the embedded libghostty renders the kitty graphics protocol (APC `ESC _ G …`)
inside helm is unverified — ghostty proper supports it, but the answer for the
embed's render path has to come from a human looking at a helm terminal. The check
is `tools/kitty-icat-test.sh`: a self-contained script (embedded base64 PNG, no
dependencies) that emits a 32x32 four-color square via a single
`ESC _ G f=100,a=T ; <base64> ESC \` transmit-and-display sequence.

Run it inside a helm terminal:

```sh
sh tools/kitty-icat-test.sh
```

- **Colored square between the marker lines** → kitty graphics work in the embed;
  tools like `kitty +kitten icat`, `timg -pk`, and agent image output are viable.
- **Nothing between the markers** → the surface consumed the APC but did not render
  it: protocol parsed, graphics not implemented/enabled in the embed's renderer.
- **Raw base64 garbage on screen** → the APC was not consumed at all.

Record the observed outcome here when a human runs it. Same square in Ghostty.app
or kitty makes a good positive control.

## Pin change 2026-07-27 — tag 1.3.1 + a local patch, for one app runtime

The pin is still exact 1.3.1 (`b0930320`), but it is now expressed as **tag plus
patch** rather than `exact:`. Both manifests point at `vendor/libghostty-spm`, a
gitignored checkout produced by `scripts/patch-libghostty.sh`; the patch itself
is committed at `Patches/libghostty-spm-multi-surface-wakeup.patch`. Full
provenance, the diffstat, and the retirement condition are in docs/VENDORED.md.

Why: one `TerminalController` is one `ghostty_app_t`, and helm was creating one
per tab, so a full libghostty runtime was allocated per terminal. Ghostty.app and
cmux both run a single runtime with N surfaces. The wrapper structurally supports
that everywhere — `retainedBridges` is an array, per-surface delegate routing
demultiplexes on `ghostty_surface_userdata` — except in two `internal`
single-valued closures, `TerminalController.onWakeup` and `.shouldProcessWakeup`.
A second surface's `rebuildIfReady` overwrote the first's handlers, and either
surface's `tearDownSurface` nil'd them for everyone. Both were reproduced as
failing tests against the unpatched tag first, then fixed by keying the handlers
on `TerminalCallbackBridge` identity and fanning the wakeup out.

The binary target is untouched: the xcframework URL and checksum are still
upstream's, so the shell-integration tree pinned above still cannot skew from
the binary. This is a Swift-source patch only.

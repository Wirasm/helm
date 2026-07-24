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

## Fallback

If libghostty fights for more than a day of effort: SwiftTerm (pure-Swift terminal
view, easy embed, weaker rendering) as a stopgap `TerminalPane` behind the same
interface, and revisit libghostty when its embedding API stabilizes. The pane's
interface (spawn shell, feed input, resize, survive toggle) stays identical either way.

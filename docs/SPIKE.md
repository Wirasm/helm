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

## Build steps

1. `brew install zig` — NOTE: ghostty pins an exact zig version; check
   `vendor/ghostty/build.zig` (it errors loudly on mismatch). If brew's zig is ahead,
   install the pinned version via zigup or a tarball.
2. `scripts/build-ghosttykit.sh` — clones ghostty into `vendor/ghostty` (gitignored)
   and runs `zig build xcframework`, producing
   `vendor/ghostty/macos/GhosttyKit.xcframework` (the same artifact Ghostty's own
   macOS app consumes — that app is the canonical embedding reference:
   `vendor/ghostty/macos/Sources/Ghostty/` shows the Swift wrapper layer).
3. Add to `Package.swift`:
   `.binaryTarget(name: "GhosttyKit", path: "vendor/ghostty/macos/GhosttyKit.xcframework")`
   and depend on it from the Helm target.
4. Implement `TerminalPane` against the C API (`ghostty.h`): app create → surface
   create (NSView-backed) → feed keyboard/mouse/resize events, following the reference
   wrapper. Keep our wrapper thin and version-pinned (the API is pre-1.0; note the
   ghostty commit SHA in this file when it works).

## Known risks (why this is a spike)

- **libghostty API churn**: pre-1.0 C API; the embedding contract is "whatever the mac
  app does this commit." Mitigation: pin the vendored SHA, copy patterns from
  `macos/Sources/Ghostty/` rather than inventing.
- **zig version pinning**: build breaks on wrong zig; not brew-friendly.
- **SPM + xcframework quirks**: binaryTarget with a locally-built xcframework usually
  works; if SPM fights, the fallback is graduating to XcodeGen early (project.yml is
  ~30 lines) — xcodegen is already installed.
- **Event plumbing volume**: keyboard/IME/mouse/scroll forwarding is the bulk of the
  embed work. The reference wrapper is the map; budget most of the spike here.

## Fallback

If libghostty fights for more than a day of effort: SwiftTerm (pure-Swift terminal
view, easy embed, weaker rendering) as a stopgap `TerminalPane` behind the same
interface, and revisit libghostty when its embedding API stabilizes. The pane's
interface (spawn shell, feed input, resize, survive toggle) stays identical either way.

# Vendored third-party assets

Helm ships its runtime dependencies in the bundle and never fetches anything
at runtime. Every vendored asset is pinned here — exact version, source URL,
and sha256 — so a bump is always a deliberate, recorded act (the same discipline
as the Ghostty pin below).

All assets are wired in BOTH manifests — `Package.swift` (`resources:` on the
Helm target) and `project.yml` (the `buildPhase: resources` entries) — keep
them in lockstep.

## marked 18.0.7 — `Sources/Helm/Resources/marked.min.js`

Converts markdown artifacts to HTML inside the canvas's document
webview (injected via WKUserScript; the page calls `marked.parse`).

- **Version**: 18.0.7 (latest stable at vendoring time, 2026-07-25)
- **Source**: <https://cdn.jsdelivr.net/npm/marked@18.0.7/lib/marked.umd.js>
  (jsdelivr's mirror of the `marked` npm package's prebuilt UMD bundle — the
  package ships it already minified; it assigns `globalThis["marked"]`, which
  is what the injection relies on. Saved locally as `marked.min.js`.)
- **sha256**: `7a1f8c5e7226b75ff16644bdb2c0130d2ae7371e7ea3106c2d6dac77ab0ff7b6`
- **License**: MIT (MarkedJS, © 2018–2026 MarkedJS; © 2011–2018 Christopher Jeffrey)

## mermaid 11.16.0 — `Sources/Helm/Resources/mermaid.min.js`

Renders the ```mermaid fences in markdown artifacts (rewritten to
`<pre class="mermaid">` containers inside the document webview) and
`<pre class="mermaid">` blocks in .html artifacts (injected via WKUserScript).
The prp-diagram skill writes these artifacts and documents exactly this
arrangement: the artifact carries the diagram source, the consuming UI
provides the renderer.

- **Version**: 11.16.0 (latest stable 11.x at vendoring time, 2026-07-24)
- **Source**: <https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js>
  (jsdelivr's mirror of the `mermaid` npm package's prebuilt UMD/IIFE bundle;
  it assigns `globalThis["mermaid"]`, which is what the injection relies on)
- **sha256**: `74d7c46dabca328c2294733910a8aa1ed0c37451776e8d5295da38a2b758fb9b`
- **License**: MIT (Mermaid, © Knut Sveidqvist and contributors)

Verify after any re-download:

```sh
shasum -a 256 Sources/Helm/Resources/marked.min.js Sources/Helm/Resources/mermaid.min.js
```

To bump either: download the new pinned version from the same URL pattern,
update the version + hash here, and re-open a markdown artifact with diagrams
(e.g. a prp-diagram plan supplement) to confirm conversion and every diagram
type still render.

## @quickdrawjs/core 0.2.0 — `.claude/skills/helm-board/quickdraw/`

The drawing engine behind a **board** (#111). **Not a bundle resource, and deliberately not in
either manifest**: helm never injects it, and no helm surface imports it. `new-board.sh` copies
this directory *beside an artifact*, where the page loads it as a sibling over
`helm-canvas://` — so the pinned bytes travel with the board and a board renders the same in six
months as it does today. That is also why it is 180 KB in the repository and 0 KB in the app.

- **Version**: 0.2.0 (published 2026-08-02; latest at vendoring time, 2026-08-07)
- **Source**: the `@quickdrawjs/core` npm tarball, `package/src/` — nine files of unminified,
  dependency-free ESM with file extensions written, which is what makes it importable with no
  bundler and no build step. Upstream is <https://github.com/nmndwivedi/quickdraw>
  (monorepo, `packages/core`).
- **Modified**: no. Copied verbatim, verified byte-identical to the tarball (`diff -r` clean).
- **License**: MIT (© Naman Dwivedi)
- **sha256**: pinned per file in `.claude/skills/helm-board/quickdraw/VENDORED.txt`, and
  **re-checked by `bash .claude/skills/helm-board/test.sh`** — a vendored dependency whose bytes
  nobody verifies is a CDN with extra steps.

**Why vendored rather than pinned to a CDN.** It was four days old and on its fifth version in
two days when it was chosen; the risk with a young single-author library is normally *you are
stuck*, and vendoring converts that into *you own a file*. There is nothing to upgrade and
nothing to fetch. Two upstream fixes worth sending are drafted at
`~/.prp/helm-3ec376fc/reports/quickdraw-upstream.md`; keeping this copy legible and close to
upstream is what makes a diff offerable rather than a private fork.

To bump: re-download the tarball, `diff -r` against this directory, regenerate `VENDORED.txt`
(`cd .claude/skills/helm-board && shasum -a 256 quickdraw/*`), and open a board to confirm it
still renders and still takes a stroke.

## Ghostty — `Packages/GhosttyTerminal/`

helm's terminal is official Ghostty, built by us, plus the Swift wrapper that hosts it in an
`NSView`. No third party's binary and no patches.

**The pin is two lines** at the top of `Packages/GhosttyTerminal/Package.swift`:
`ghosttyCommit` (a full `ghostty-org/ghostty` sha) and `ghosttyKitChecksum`. Nothing else
records the commit; everything below follows from it.

Three things must come from that one commit, and `scripts/bump-ghostty.sh` moves the first two
together:

1. **GhosttyKit.xcframework** — Ghostty's own
   `zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Dxcframework-target=universal`
   (the build Ghostty.app itself links; macOS arm64 + x86_64), unpatched. Published as the only
   asset of the release `ghostty-<first 12 of the commit>` on Wirasm/helm, a prerelease that is
   not a helm release, and consumed as `binaryTarget(url:checksum:)`. The gate downloads it and
   needs no zig.
2. **Shell integration** — `Sources/Helm/Resources/ghostty/shell-integration/`, Ghostty's
   `src/shell-integration/` copied verbatim. `GhosttyResources` (GhosttyConfig.swift) points
   `GHOSTTY_RESOURCES_DIR` at it, so the scripts must be the ones the binary was built with.
   Bundled as a directory in both manifests (SPM `.copy("Resources/ghostty")`; xcodegen
   `type: folder`) so zsh's hidden `.zshenv` survives into the app bundle. git holds the
   bytes; there is no second hash list to keep.
3. **benchd's libghostty-vt** — not in the tree yet (M5b, `docs/future-planning/bench-roadmap.md`).
   helm and benchd must parse terminal bytes identically, so when it lands it is built from the
   same checkout `bump-ghostty.sh` makes (`zig build -Demit-lib-vt` in
   `.build/ghostty/<commit12>`), and this section is where that coupling stays written down.

**The wrapper** (`Packages/GhosttyTerminal/Sources/GhosttyTerminal`, about 7.1k lines) is the
macOS slice of [Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm)'s
`GhosttyTerminal` target at tag `1.6.20260922` (`b7f888e`), MIT (© Lakr233; `LICENSE` beside
it). helm owns it now. What was taken out: UIKit; the in-memory session and the host-managed IO
backend it needs (a Ghostty patch of Lakr233's, not official Ghostty); the SwiftUI view layer
(`TerminalViewState`, the representables, `TerminalSurfaceView`), since helm hosts
`AppTerminalView` in its own `GhosttyHostView`; the snapshot helper; and the resources lookup
(`GhosttyRuntimeResources`), which helm's `GhosttyResources` replaces. Its one other dependency
is `MSDisplayLink`, exact `2.2.0`. It is outside `make lint` on purpose: its text stays close to
upstream's so a fix there can still be diffed in by hand.

**Why not Lakr233's package, as before.** Its `GhosttyKit.xcframework` is Ghostty with 17 of
its own patches applied (`Patches/ghostty/` there), several of which change behaviour: resize
and prompt-redraw frame holds, a scroll fix, the host-managed backend. The operator's ruling
(2026-09-26): official Ghostty, and if we need to own something, we own it. Rendering is
therefore Ghostty.app's, including across a drag-resize.

**What helm used to patch, and where each fix lives now.** Until 2026-09-26 helm built against
libghostty-spm `1.3.1` with three patches of its own. All three are in the wrapper as taken:

- **Multi-surface wakeups.** 1.3.1 held `onWakeup` as one slot, so a second surface on the
  shared `TerminalController` stole the first's wakeups and closing any pane stalled the rest.
  Now `addWakeupObserver` / `removeWakeupObserver`; `Tests/GhosttyTerminalTests/WakeupFanOutTests`.
- **The clipboard a write names (#297).** Every write landed on `NSPasteboard.general`, so
  `OSC 52` at the selection target replaced the operator's clipboard. Now
  `TerminalClipboardWrite`: only the standard clipboard is written, selection and primary
  (ghostty's raw `2`) are dropped, never redirected; `Tests/GhosttyTerminalTests/ClipboardWriteTests`.
  Reads are not guarded, and cannot usefully be: ghostty resolves an `OSC 52` read to the
  standard clipboard before any callback runs (`Surface.zig`), so every read arrives as
  `.standard`. A protected paste or `OSC 52` read goes to the wrapper's confirmation hook,
  and helm answers yes (`TerminalSession+Clipboard.swift`), as the old wrapper did: helm has
  no prompt to ask with, so an `OSC 52` read is still not guarded.
- **A handled `open_url` reported as handled.** Otherwise ghostty also runs its own
  `/usr/bin/open`, whose stderr reader spins forever (ghostty-org/ghostty#13480): measured at
  seven threads and 586 CPU-hours on a helm up nine days. The callback claims `open_url` when
  the surface delegate conforms to `TerminalSurfaceOpenURLDelegate`;
  `TerminalOpenURLOwnershipTests` pins helm's conformance.

**To bump** (Ghostty released, or main has something we want):

```sh
scripts/bump-ghostty.sh            # ghostty main now; or pass a full commit sha
just check                         # the full gate, displays awake (AGENTS.md)
```

The script needs zig at the commit's `minimum_zig_version` (0.16.0 as of `6301810`), Xcode's
Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) and `gh`. It builds, publishes
the release, rewrites the two pin lines and refreshes the shell integration.
`--no-publish` builds and repins without the release, for a dry run. A changed `ghostty.h` shows
up as a compile error in the wrapper; fix it there. Then look at a live isolated helm (text,
colours, keys, clipboard, a ⌘-click, several panes redrawing) before opening the PR, because no
gate draws a frame.

## InjectionNext 2.0.1 + Inject 1.6.0 — hot reload (SPM, DEBUG only)

Not vendored files but pinned SPM dependencies, recorded here for the same
reason: both are exact pins wired into BOTH manifests, and both patch the
running process, so a bump is a deliberate act.

Together they let a recompiled Swift file be swapped into a LIVE helm without
relaunching. That matters more here than in a normal app: helm owns its ptys
in-process, so every relaunch kills whatever agent was running in the terminal.
Injection touches only helm's own recompiled Swift — libghostty's binary
xcframework, the Metal renderer and the shells beneath it are never swapped, so
the terminals survive a UI edit.

- **InjectionNext**: <https://github.com/johnno1962/InjectionNext>, exact 2.0.1
  — loads the injection bundle and connects to the InjectionNext watcher. Its
  code compiles to nothing in a release build. Supersedes InjectionIII and
  HotReloading (both retired upstream).
- **Inject**: <https://github.com/krzysztofzablocki/Inject>, exact 1.6.0 — the
  SwiftUI half: `@ObserveInjection` + `.enableInjection()` force a redraw when
  a swap lands. Release builds compile these to no-ops.
- **Licenses**: MIT (InjectionNext, © John Holdsworth; Inject, © Krzysztof
  Zabłocki).

Wired in three places, keep them in lockstep:

1. `Package.swift` — the two `.package(exact:)` pins, both products on the Helm
   target, and `linkerSettings: [.unsafeFlags(["-Xlinker", "-interposable"],
   .when(platforms: [.macOS], configuration: .debug))]`.
2. `project.yml` — the same two pins under `packages:`, the same two products
   under `dependencies:`, and `configs.Debug.OTHER_LDFLAGS` carrying the same
   two flags. Release must NOT carry them.
3. The views that opt in: `RootView`, `TerminalStrip` and `ArtifactPane` each hold
   `@ObserveInjection private var inject` and end their body with
   `.enableInjection()`. A view without those two lines still compiles and runs —
   it just won't redraw on a swap. (`SidebarColumn` and `RoomDetailView` were on
   this list until the kild layer was removed at `e544746`.)

Interposing is what makes it work: the Debug linker emits indirect stubs that
injection repoints. Without the flag, calls are direct and a swap does nothing.

To use: run the InjectionNext watcher against this directory, then edit and save
a file in `Sources/Helm/`. To bump: change the version in BOTH manifests
together and re-run `xcodegen generate`.

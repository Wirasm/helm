# Vendored third-party assets

Helm ships its runtime dependencies in the bundle and never fetches anything
at runtime. Every vendored asset is pinned here — exact version, source URL,
and sha256 — so a bump is always a deliberate, recorded act (same discipline
as the libghostty pin in docs/SPIKE.md).

All assets are wired in BOTH manifests — `Package.swift` (`resources:` on the
Helm target) and `project.yml` (the `buildPhase: resources` entries) — keep
them in lockstep.

## marked 18.0.7 — `Sources/Helm/Resources/marked.min.js`

Converts markdown artifacts to HTML inside the artifact pane's document
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

## ghostty shell-integration — `Sources/Helm/Resources/ghostty/shell-integration/`

Ghostty's shell-integration script tree (bash, elvish, fish, nushell, zsh),
bundled so OSC 133 prompt marks (⌘↑/⌘↓ jump-to-prompt), command-finished
events, and OSC 7 pwd reports work with nothing else installed.
`GhosttyResources` (GhosttyConfig.swift) points `GHOSTTY_RESOURCES_DIR` at the
bundled `ghostty/` dir first; an installed Ghostty.app's copy is only the
fallback. Bundled as a directory in both manifests (SPM
`.copy("Resources/ghostty")`; xcodegen `type: folder`) so the hierarchy — and
zsh's hidden `.zshenv` — survives into the app bundle.

- **Version**: ghostty commit `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`
  (2026-07-10, during the 1.3.2 dev cycle; no release tag). This is the EXACT
  source commit the pinned embed was built from: libghostty-spm 1.3.1's
  GhosttyKit.xcframework carries the version string
  `1.3.2-HEAD-+35e1a0160` (verify: `strings .build/artifacts/libghostty-spm/
  libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a | grep
  1.3.2`), so scripts and binary cannot skew.
- **Source**: `src/shell-integration/` from
  <https://github.com/ghostty-org/ghostty/archive/35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58.tar.gz>
  (source tarball sha256
  `057c6c2a8851bef9d80a6c628124fbcfeb12876fc72c31c67a9c1ecde56f999e`), copied
  verbatim — no edits.
- **License**: MIT (Ghostty, © Mitchell Hashimoto); `bash-preexec.sh` is MIT
  (© Ryan Caloras), vendored by ghostty upstream.
- **File sha256** (`cd Sources/Helm/Resources/ghostty && find
  shell-integration -type f | sort | xargs shasum -a 256`):

```text
24d8b80577fa0e630e89a6b0284205323df568559ea85b4168074714832996e4  shell-integration/bash/bash-preexec.sh
9c250c90d00f11c02a4245e940e5330e7e5d1eabae46d70c53b141b46b4921f0  shell-integration/bash/ghostty.bash
9fb49e9e885e45fcfbb0c41827ee68e65fc397f84b2ff2c72b1221f20070e7fe  shell-integration/elvish/lib/ghostty-integration.elv
d78d03a5f602cd95eb15f7310ce42c96c560bc28dec37a792576535eefac8bf3  shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish
b5bf0a6f4b25d21e06160056d3a201845570b31fb2b9ce117736c6d914d94bb4  shell-integration/nushell/vendor/autoload/ghostty.nu
329f4ba5090269248e764caa8d9527687e4f5d6d9104745e690c051269500c50  shell-integration/README.md
a9885383cd13cd9f0297b1d13a7bade2526f7f91c0a097f255e9a39a508fcba4  shell-integration/zsh/.zshenv
1a2bcb867f06667d5d743221aea42b1d322f3ae402e1a62ba941cba3c5d17f19  shell-integration/zsh/ghostty-integration
```

To bump: this tree moves ONLY together with the libghostty-spm pin. When the
pin changes, read the new xcframework's embedded version string for the build
commit, re-fetch `src/shell-integration/` at that commit, and update the
commit + hashes here.

## libghostty-spm 1.3.1 + helm patch — `vendor/libghostty-spm` (LOCAL, TEMPORARY)

Not a vendored file and no longer a plain SPM pin: helm currently builds against
a LOCAL checkout of libghostty-spm at tag `1.3.1` with one patch applied. Both
manifests point at `vendor/libghostty-spm` (gitignored); `scripts/patch-libghostty.sh`
clones and patches it.

- **Base**: <https://github.com/Lakr233/libghostty-spm.git>, tag `1.3.1`,
  revision `b0930320739324886590e865d571eb5dd7073912` — the same exact pin
  docs/SPIKE.md records. The patch does not touch the binary target, so the
  `GhosttyKit.xcframework.zip` URL and checksum are upstream's, unchanged.
- **Patch**: `Patches/libghostty-spm-multi-surface-wakeup.patch` (a `git
  format-patch` output; apply with `git am`). 3 files, +184/−16, of which 120
  lines are tests.
- **License**: MIT (libghostty-spm, © Lakr233).

**What it fixes.** `TerminalController.onWakeup` / `.shouldProcessWakeup` were
single-valued closures. A `TerminalSurfaceCoordinator` claimed both on
`rebuildIfReady` and nil'd both on `tearDownSurface`, so a controller could only
ever drive ONE surface: a second surface stole the first's wakeups, and closing
any surface stopped ticking for every survivor. Both defects were reproduced
against the unpatched tag before the fix was written. The patch replaces the two
slots with a registry keyed on `TerminalCallbackBridge` identity — the same key
`retain`/`remove`/`retainedBridgeCount` already use — so each coordinator
subscribes on build, drops only its own entry on teardown, and `handleWakeup`
ticks the app once (`ghostty_app_tick` is app-wide) and fans out to every
subscriber that wants the frame. Behaviour with zero or one surface is unchanged.

**Why helm needs it.** One `TerminalController` is one `ghostty_app_t`. Without
the patch every terminal tab carried a full libghostty runtime; with it, helm
runs one runtime with N surfaces the way Ghostty.app does. `TerminalManager`'s
header documents the ownership model that depends on this.

**Where the pin lives now.** A local path dependency is not recorded in
`Package.resolved` — SPM dropped the libghostty-spm entry when the manifests
stopped naming a URL. The exact revision therefore lives HERE and in
`scripts/patch-libghostty.sh` (`tag=1.3.1`), and nowhere else. Retiring the
local pin puts it back into `Package.resolved` where the rest of the deps are.

**RETIREMENT CONDITION** — this local pin is temporary. In order of preference:

1. Upstream merges the patch → drop `vendor/`, `Patches/` and
   `scripts/patch-libghostty.sh`, and return BOTH manifests to
   `exact: "<new tag>"`.
2. Upstream declines or goes quiet → push `helm/multi-surface-wakeup` to a fork
   and pin both manifests to the fork URL + an exact `revision:` (never a
   branch). Record the fork URL and PR link here.

Until one of those happens the branch does not build from a clean clone without
running `scripts/patch-libghostty.sh` first. Verify the patch with:

```sh
scripts/patch-libghostty.sh
(cd vendor/libghostty-spm && swift test --filter TerminalLifecycle)
```

Four tests in `TerminalThemeConfigurationTests` fail in that suite both with and
without the patch — a pre-existing upstream/environment failure at tag 1.3.1,
not something this patch introduced.

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

# Vendored third-party assets

Helm ships its runtime dependencies in the bundle and never fetches anything
at runtime. Every vendored asset is pinned here — exact version, source URL,
and sha256 — so a bump is always a deliberate, recorded act (same discipline
as the libghostty pin in docs/SPIKE.md).

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
- **Patches**, applied in this order by `scripts/patch-libghostty.sh` (both are `git
  format-patch` output; applied with `git am`):
  1. `Patches/libghostty-spm-multi-surface-wakeup.patch` — 3 files, +184/−16, of which
     120 lines are tests.
  2. `Patches/libghostty-spm-clipboard-destination.patch` — 4 files, +161/−3, of which
     49 lines are tests.
- **License**: MIT (libghostty-spm, © Lakr233).

**Each patch carries its own marker.** The script verifies an existing `vendor/` by
grepping for a symbol each patch introduces — one per patch, not one for the set. That is
not tidiness: a `vendor/` left over from before patch 2 still contains patch 1's marker, so
a single check reports `OK ... patch applied` and exit 0 while helm builds against a tree
that eats the operator's clipboard. Measured both ways on 2026-08-10 against exactly that
tree — the old script said OK, the current one names the missing patch and exits 1.

**Adding a third patch is three lines**: drop the file in `Patches/` and add its
`<file>|<marker>|<marker file>` row to the `patches` array. Nothing else in the script
knows how many there are.

## Patch 1 — multi-surface wakeup

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

## Patch 2 — the clipboard a request names (#297)

**What it fixes.** `writeClipboard` bound its `clipboard: ghostty_clipboard_e` argument to
`_`, so every write — whichever clipboard it named — landed on `NSPasteboard.general`. A
program running in a pane could therefore replace the operator's system clipboard with
`OSC 52` at the *selection* target, silently. Reproduced live before the fix; fixed and
re-measured after, with `OSC 52 ;c;` still working as the negative control:

```
before                                        after
;c;  -> WROTE the pasteboard                  ;c;  -> WROTE the pasteboard
;s;  -> WROTE the pasteboard                  ;s;  -> pasteboard UNTOUCHED
;p;  -> WROTE the pasteboard                  ;p;  -> pasteboard UNTOUCHED
```

The patch resolves the argument once, through a new public
`TerminalClipboardDestination`, and writes only for `.standard` — Apple platforms have
exactly one pasteboard, `selection` and `primary` are X11 buffers with nothing to map them
onto, so a write aimed at one is **refused rather than redirected**. It also stops the
runtime config claiming a selection clipboard, which is what Ghostty.app answers.

**Three things worth knowing before touching it, each of which cost a measurement:**

- **`supports_selection_clipboard = false` does not close the OSC 52 route** and was never
  going to. ghostty reads that flag in exactly two places — the copy-on-select target
  (`Surface.zig:2381`) and the middle-click paste source (`:4035`), both mouse routes.
  `Surface.clipboardWrite` calls straight through to `setClipboard` without asking. Hence
  the resolution in the callback; the flag is there because it is the truth, not because
  it is the fix.
- **`unknown` is reachable, not defensive.** `ghostty.h` declares two constants while
  ghostty's own `apprt.Clipboard` has three (`standard = 0`, `selection = 1`,
  `primary = 2`) and passes `@intFromEnum` across the boundary — so `OSC 52 ;p;` arrives as
  a raw `2` naming no C constant, and reached the pasteboard before this.
- **The read direction is not fixed here and cannot be.** The symmetric guard is the
  obvious thing to add and it is a trap. ghostty calls
  `startClipboardRequest(.standard, .{ .osc_52_read = clipboard })` (`Surface.zig:1049`),
  carrying the requested kind only to pick the reply's `c`/`s`/`p` byte — so every read
  arrives at the callback as `.standard` whatever the program asked for. Measured by
  inverting the guard: refusing `.standard` stopped `;c;?`, `;s;?` and `;p;?` alike. The
  one caller that passes a real choice is middle-click paste, and it consults
  `supportsClipboard(.selection)` first, so with the flag above it resolves to `.standard`
  too — meaning a guard there could only ever silently break a paste the operator asked for.

**Known limits, stated rather than hidden.** `writeClipboard` still does not read
`confirm`; it is `true` only under `clipboard-write = ask` (never ghostty's default), and
both honest answers — prompt, or refuse — are a policy for the embedding app rather than
for a wrapper. Separately, `confirmReadClipboard` answers `confirmed: true` with no prompt
at all, which makes ghostty's `clipboard-read = ask` **default** behave as `allow`: a
program in a pane can still read the operator's clipboard with `OSC 52 ;c;?`, measured
before and after this patch. Both are out of #297's scope — the second needs a prompt helm
owns — and are tracked separately.

**Why helm needs it.** helm hosts agents in its panes and the clipboard is the operator's.
`Sources/Helm/Terminals/TerminalSession.swift` carries the mouse half of the same story
(#299), and `Tests/HelmTests/Terminals/TerminalClipboardDestinationTests.swift` executes
this decision from helm's own gate — a marker grep proves a patch was applied and says
nothing about what it decides.

## Where the pin lives, and how it retires

**Where the pin lives now.** A local path dependency is not recorded in
`Package.resolved` — SPM dropped the libghostty-spm entry when the manifests
stopped naming a URL. The exact revision therefore lives HERE and in
`scripts/patch-libghostty.sh` (`base_tag=1.3.1`), and nowhere else. Retiring the
local pin puts it back into `Package.resolved` where the rest of the deps are.

**RETIREMENT CONDITION** — this local pin is temporary. In order of preference:

1. Upstream merges the patches → drop `vendor/`, `Patches/` and
   `scripts/patch-libghostty.sh`, and return BOTH manifests to
   `exact: "<new tag>"`.
2. Upstream declines or goes quiet → push `helm/patches` to a fork
   and pin both manifests to the fork URL + an exact `revision:` (never a
   branch). Record the fork URL and PR link here.

They retire independently: upstream taking one and not the other leaves `Patches/` holding
whichever is left, and the script's array is already per-patch.

Until one of those happens the branch does not build from a clean clone without
running `scripts/patch-libghostty.sh` first. Verify the patches with:

```sh
scripts/patch-libghostty.sh
(cd vendor/libghostty-spm && swift test --filter TerminalLifecycle)
(cd vendor/libghostty-spm && swift test --filter TerminalClipboardDestination)
```

Four tests in `TerminalThemeConfigurationTests` fail in that suite both with and
without the patches — a pre-existing upstream/environment failure at tag 1.3.1,
not something they introduced.

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

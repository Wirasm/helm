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

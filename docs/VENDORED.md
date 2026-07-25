# Vendored third-party assets

Helm's artifact pane is offline by rule: renderers ship in the bundle, and the
app never fetches anything at runtime. Every vendored asset is pinned here —
exact version, source URL, and sha256 — so a bump is always a deliberate,
recorded act (same discipline as the libghostty pin in docs/SPIKE.md).

Both assets are wired in BOTH manifests — `Package.swift` (`resources:` on the
Helm target) and `project.yml` (the `buildPhase: resources` entry) — keep them
in lockstep.

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

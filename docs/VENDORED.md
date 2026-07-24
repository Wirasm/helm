# Vendored third-party assets

Helm's artifact pane is offline by rule: renderers ship in the bundle, and the
app never fetches anything at runtime. Every vendored asset is pinned here —
exact version, source URL, and sha256 — so a bump is always a deliberate,
recorded act (same discipline as the libghostty pin in docs/SPIKE.md).

## mermaid 11.16.0 — `Sources/Helm/Resources/mermaid.min.js`

Renders the ```mermaid fences in markdown artifacts (each as an inline
WKWebView island) and `<pre class="mermaid">` blocks in .html artifacts
(injected via WKUserScript). The prp-diagram skill writes these artifacts and
documents exactly this arrangement: the artifact carries the diagram source,
the consuming UI provides the renderer.

- **Version**: 11.16.0 (latest stable 11.x at vendoring time, 2026-07-24)
- **Source**: <https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js>
  (jsdelivr's mirror of the `mermaid` npm package's prebuilt UMD/IIFE bundle;
  it assigns `globalThis["mermaid"]`, which is what the injection relies on)
- **sha256**: `74d7c46dabca328c2294733910a8aa1ed0c37451776e8d5295da38a2b758fb9b`
- **License**: MIT (Mermaid, © Knut Sveidqvist and contributors)

Verify after any re-download:

```sh
shasum -a 256 Sources/Helm/Resources/mermaid.min.js
```

To bump: download the new pinned version from the same URL pattern, update the
version + hash here, and re-open a diagrams artifact (e.g. a prp-diagram plan
supplement) to confirm every diagram type it uses still renders. The resource
is wired in BOTH manifests — `Package.swift` (`resources:` on the Helm target)
and `project.yml` (the `buildPhase: resources` entry) — keep them in lockstep.

---
name: helm-canvas
description: Put an artifact in front of the operator as a helm canvas — a rendered markdown or HTML file that appears as a tab beside their terminal. Use after writing a plan, report, review, diagram, or interactive page that is worth looking at rather than reading in a terminal; when the operator says "open it in the canvas", "show me that", "render this", "put it on screen"; or via /helm-canvas.
---

# The canvas

**This skill is the capability surface: what a canvas *is*, and what it can do.** It does not say
what to put in one, what a good one looks like, or when a page beats a document. Those are
decisions, and they belong to you or to a more specific skill — see *Where conventions live* at the
end.

**helm is the macOS terminal application this session is running inside.** Not a library, not a
dependency, and not something in the repository you are working in — you could be in any repo and
still be in helm. Nothing in the current project needs to know about it, and you will not find it
there. Do not go looking.

A **canvas** is a pane beside the terminal that renders a markdown or HTML file. You put something
there by writing a file and asking helm to show it.

**It appears; it does not seize.** The artifact arrives as a tab the operator can reach. It does not
take the keyboard and does not replace whatever they are currently reading. Bringing it forward
stays their action.

## Opening one

```bash
~/.claude/skills/helm-canvas/push.sh /absolute/path/to/artifact.md
```

- The path must be **absolute**, and the file must exist.
- Only **`.md` `.markdown` `.mdown` `.html` `.htm`** are renderable.
- Artifacts go in this project's `~/.prp/<key>/` store, **never in the repo**.
- **Read the exit code.** Every refusal has its own — `2` wrong number of arguments, `3` not
  absolute, `4` no such file, `5` an extension helm has no renderer for, `6` no terminal it could
  reach *or the write to it failed*, `7` the path contains control characters. Each says on stderr
  what to do about it. **Zero means the bytes reached a terminal**, not merely that the script ran.

**Do not hand-roll the `printf` yourself.** The push is an escape sequence, and an escape sequence
only does anything if it reaches the terminal helm is parsing — which your tool call's stdout is
not. Your harness captures it, and you have no controlling terminal at all: measured from a Claude
Code tool call, `tty` is `??`, the session is `0`, and `/dev/tty` will not open. A bare `printf`
comes back to you as text, the operator sees nothing, and nothing anywhere reports an error
(helm #184). `push.sh` exists to find a pty you can actually write to, and to refuse out loud when
there is none.

It works the same from a shell the operator typed into, from a `Makefile`, or from a script — that
path was never broken, and the script does not change it.

**An OSC 8 hyperlink is not a second way in.** A ⌘-click on one does not reach helm from inside a
TUI; your own terminal UI captures the mouse first (helm #124).

## The two renderers

**`.md` — helm is the renderer.** It converts the markdown, renders ```mermaid fences, and applies
its own type scale. The file you write is input, not output.

**`.html` — your bytes are the page.** helm serves the file itself. Whatever you write is what
renders.

## What an HTML canvas can do

A canvas is a real web page on a real origin — `helm-canvas://<host>/` — not a preview pane. So:

- **JavaScript runs, and runs with no click.** A pushed canvas renders and executes immediately.
- **Sibling files are served.** The artifact's directory is the read boundary, so `./app.js`,
  `./data.json`, `./style.css`, `./img/x.png` beside the artifact all load. This is the primitive
  most interactive canvases are built on.
- **ES modules work**, resolved against that same directory — so a library vendored beside the
  artifact can be `import`ed with no bundler and no build step.
- **Origin-scoped browser APIs work**, `localStorage` among them.
- **The network is open.** A canvas may `fetch` a remote host, open a WebSocket, load a remote
  `<script>` or `<img>`. helm serves no content-security policy and does not police what an artifact
  reaches — a canvas that pulls live data or polls an API is a canvas worth having. One CSP was
  built and rejected (helm #209): blocking belongs in hooks and sandboxes, not in the app.
- **Nothing outside the artifact's directory is readable over `helm-canvas://`.** Both sides are
  canonicalized — `..` collapsed *and* symlinks followed — so containment is decided about the file
  that would actually be read, not about the text of the request. This is about the local
  filesystem, and says nothing about the network.

There is **no server on the canvas's own origin**. Siblings are served as static files, so anything
wanting a request/response cycle of its own has nothing local to talk to — reach a remote host, or
do it in the page.

**Your artifact keeps running whenever it is opened**, long after the session that wrote it ends. It
is a page in the operator's window, not a transcript.

## Taking a dependency

Three routes, all of which work. They differ in what happens six months from now, and that is the
only axis worth thinking about.

- **A CDN `<script src>`** — nothing to set up. **A pinned URL renders the same later; an unpinned
  one does not.** `https://cdn.jsdelivr.net/npm/chart.js` resolves to whatever is current;
  `https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js` is fixed.
- **`curl` it beside the artifact** and `<script src="./lib.min.js">`. Measured across fifteen
  common libraries, all fifteen ship a browser-ready file — a UMD/IIFE bundle or dependency-free
  ESM — reachable this way in about a quarter of a second (helm #200). The artifact then renders
  identically forever and needs no network at all.
- **`bun add x && bun build entry.js --outfile lib.js --minify --target browser`** for the rare
  library shipping no browser build. About 1.5 s, unattended, nonzero exit if the network is gone.

**Vendoring a library's ESM *source* works only if it ships browser-ready ESM.** `@quickdrawjs/core`
does — no dependencies, imports written with file extensions. An ordinary TypeScript-compiled
package does not: `import './thing'` is unresolvable in a browser. That is the case the third route
exists for.

## What you can check yourself

**An `.html` artifact you can render and look at** — a headless browser, a screenshot, whatever this
environment already has. It works because the page is self-contained: the file you render is the
page the operator sees.

**A markdown canvas you cannot.** helm is the renderer, so opening the `.md` yourself shows raw
markdown. There is no way to see a markdown canvas as the operator sees it.

## Limits that are helm's, not yours

These are properties of the platform. They are not preferences, and you cannot code around them.

**The operator's annotations land beside the artifact, never inside it.** When they mark up a
canvas, helm writes their notes to a sidecar file — precisely because you rewrite the artifact and
would clobber anything kept inside. Read the notes if they appear; only ever write the artifact.

**A mermaid node is addressable in four families only.** helm hands back the identifier from your
```mermaid fence — name a node `phase2` and a mark comes back as `phase2`, which you can grep for
and edit (helm #113). That holds for **flowchart, class, state and er**. `mindmap` and
`sequenceDiagram` put no author-written identifier in the rendered output, so a mark degrades to
quoted text with nothing to anchor to; `gitGraph` and `pie` produce no addressable nodes at all.
For a diagram the operator must be able to point at, those four families or your own HTML ids are
the options that work.

**Sibling `fetch` reports a real status** — 200 for bytes, 404 for a sibling that is not there, 403
for one the boundary refuses — so `res.ok` and `res.status` mean what they mean (helm #201).

**htmx blanks a canvas under its own defaults.** Its history handling calls `history.replaceState()`
after a swap, which a bare `WKWebView` ignores and helm does not — the page comes out empty, and
`<meta name="htmx-config" content='{"historyEnabled":false}'>` is what stops it (helm #200).

## Where conventions live

**Deliberately not here.** This skill answers "what can a canvas do". How a particular *kind* of
canvas should look — a review, a plan, a board, a diagram — is a convention worth settling once and
reusing, and it belongs in its own skill that composes with this one. Keeping them apart is the
point: a capability list that also carries taste stops being a capability list, and the taste stops
being reviewable on its own terms.

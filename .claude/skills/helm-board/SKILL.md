---
name: helm-board
description: Put a drawable board on the bench — an infinite canvas the agent authors as labelled shapes and the operator draws on by hand, with what they drew coming back as named records. Use when a diagram is something to argue with rather than read, when the operator says "draw it", "let me mark that up", "put it on a board", or when a plan wants shapes the operator can circle and reply to.
---

# The board

A **board** is a helm canvas that takes a pen. You author it as JSON — labelled boxes, arrows,
text — and it renders as an infinite canvas the operator can draw on, move around and mark up.
What they draw comes back to you on your next turn, resolved to the shapes you named.

Read `helm-canvas` first: this composes with it and does not restate it. A board is an `.html`
artifact, pushed with the same `push.sh`, subject to the same read boundary.

**The engine is `@quickdrawjs/core` 0.2.0, MIT, vendored here** — 180 KB of dependency-free ESM,
no framework, no build step, no CDN, no licence key. It is copied *beside your artifact*, so a
board renders the same in six months as it does today.

## Making one

```bash
~/.claude/skills/helm-board/new-board.sh /absolute/path/to/plan-board.html --title "The plan"
~/.claude/skills/helm-canvas/push.sh /absolute/path/to/plan-board.html
```

`new-board.sh` writes four things beside the path you gave it:

| | |
|---|---|
| `plan-board.html` | the artifact helm renders — yours to edit, but you rarely need to |
| `plan-board.document.json` | **your shapes.** This is the file you write |
| `board.js`, `board-core.js`, `quickdraw/` | the engine and helm's glue |

Read its exit code. `2` bad arguments, `3` not absolute, `4` no such directory, `5` not
`.html`/`.htm`, `6` the artifact exists (pass `--force`; the document JSON is never touched),
`7` control characters in the path, `8` a copy failed.

Boards belong in this project's `~/.prp/<key>/` store, **never in the repo** — same rule as any
artifact.

## Writing the document

`plan-board.document.json` is a flat map of records keyed by id. There is no schema, no
validator and no migration — what you write is what renders.

```json
{
  "document": {
    "store": {
      "auth-service": {
        "id": "auth-service", "typeName": "shape", "type": "geo",
        "x": 0, "y": 0, "rot": 0, "z": 1,
        "props": {
          "geo": "rectangle", "w": 200, "h": 90, "label": "Auth",
          "color": "blue", "size": "m", "dash": "solid", "fill": "none", "font": "sans"
        }
      },
      "auth-to-db": {
        "id": "auth-to-db", "typeName": "shape", "type": "arrow",
        "x": 205, "y": 45, "rot": 0, "z": 2,
        "props": { "dx": 90, "dy": 0, "bend": 0, "color": "grey", "size": "m", "dash": "solid" }
      },
      "auth-to-db-label": {
        "id": "auth-to-db-label", "typeName": "shape", "type": "text",
        "x": 215, "y": 20, "rot": 0, "z": 3,
        "props": { "text": "issues", "color": "grey", "size": "s", "font": "sans", "autosize": true, "scale": 1 }
      }
    }
  }
}
```

**The id is yours and is never regenerated.** That is the property everything else rests on:
name a shape `auth-service` and it is still `auth-service` after a reload, after the operator
moves it, and in every mark that comes back to you. Name things the way you would name them in
prose — `auth-service`, not `shape-7`.

**Positions are absolute, in page units, and nothing lays out for you.** A box is `x, y` plus
`props.w/h`; an arrow is `x, y` plus `props.dx/dy` — a vector from its own origin, not a pair of
endpoints. `z` is paint order.

**Arrows carry no label, and no binding.** `props` for `arrow`/`line` is
`{dx, dy, bend, color, size, dash}` — `label` is geo-only, `text` is text/note-only. To label an
edge, author a **separate `text` shape** and position it on the arrow by hand, as above. And an
arrow does not follow the boxes it points between: move one and the arrow stays. Both are
quickdraw's shape rather than a gap to work around locally; the second is filed upstream as a
question, not a patch.

Vocabulary that renders: `type` is `geo` | `arrow` | `line` | `text` | `note` | `draw`;
`props.geo` is `rectangle` | `ellipse` | `diamond` | `triangle` | `hexagon` | …; `color` is a
palette name (`black` `grey` `blue` `green` `red` `orange` `violet` `yellow`); `size` is
`s` | `m` | `l` | `xl`; `dash` is `solid` | `dashed` | `dotted`; `fill` is `none` | `semi` |
`solid`; `font` is `sans` | `serif` | `mono` | `draw`.

## Updating it

**Rewrite `plan-board.document.json`, then push the `.html` again.** The push is what tells helm
the artifact moved; the board takes the change as *data* and is never reloaded, so the camera,
the selection, the undo history and — the one that matters — **the operator's drawing all
survive**.

What lands is not a replace. Every id your document names is written; every id it used to name
and no longer does is removed; **everything else on the board is left alone, because everything
else is the operator's.** You own a set of ids and nothing outside it.

The cost of that, stated plainly: **a shape of yours that the operator MOVED goes back** where
your document says it is, on your next write. Ownership by id is what makes the update
non-destructive, and this is the other side of the same coin.

## What comes back

helm latches what the board says about itself to **`plan-board.state.json`**, beside the
artifact. `cat` it on your next turn. Nothing wakes you, nothing starts a turn, nothing
interrupts — the file is simply current when you next look.

```json
{
  "format": "helm.canvas-state", "version": 1,
  "writtenAt": "2026-08-07T14:02:11Z", "artifact": "plan-board.html",
  "state": {
    "format": "helm.board", "version": 1, "generation": 3,
    "counts": { "records": 9, "agent": 8, "operator": 1 },
    "shapes": [ { "id": "auth-service", "type": "geo", "label": "Auth", "owner": "agent" } ],
    "marks": [
      { "id": "shape:m9x0q2a1", "type": "draw", "points": 29,
        "pressure": { "min": 0.21, "max": 0.68, "varies": true },
        "over": { "id": "auth-service", "label": "Auth", "overlap": 17840 },
        "runnerUp": { "id": "session-store", "label": "Sessions", "overlap": 210 } }
    ]
  }
}
```

- **`marks` is what the operator put there.** Anything on the board you do not own, most often a
  freehand stroke.
- **`over` is the answer to "what did they circle", by bounding-box overlap** — not by a hit
  test. A hit test returns the topmost shape, and the spike measured it naming an arrow that
  crossed a mark's centre instead of the box underneath, then giving the right answer at a
  different zoom. Unstable is worse than blunt. The mark is excluded from its own query.
- **`runnerUp` is your confidence signal.** A top score with a runner-up at nothing is
  unambiguous; two close scores mean the mark sits between two things and you should ask.
- **`overlap` is raw intersection area in page units**, so compare the two numbers to each other
  and not to a threshold.
- **`pressure.varies` is what a hand looks like.** A synthetic pointer event reports a constant
  `0.5`; a trackpad varies. Report it if it is relevant — never claim from it that you watched
  someone draw. It is a number the page observed, and only the operator can say whose hand it was.
- **`warnings` appears only when something went wrong** in the page — a document file that would
  not load, a drawing that could not be cached. Its presence is the signal.
- `writtenAt` is a **change signal**: an identical report is not written, so it answers *when did
  the board last do something different*.

## What helm's own marking does on a board — nothing, deliberately

The container carries `data-helm-surface`, and inside a declared surface helm's annotation layer
does nothing at all: no stroke, no ink, no anchor.

That is a decision rather than a limitation. helm's mark layer resolves what it circled against
**DOM elements**, and a mounted board is one `<canvas>` with no per-shape nodes — so a helm mark
over a board could only ever name the board. The board's own ink becomes a record with an id,
resolves by overlap to a shape you named, and reaches you through the latch. It is the same
gesture with a better answer, so the two do not share the surface.

Practically: **the operator draws with the board's tools, not helm's.** helm's mark tools still
work everywhere else on the page — a heading, a caption, prose above the board — so put anything
you want them to be able to highlight *outside* the board element.

## What this does not do

Say so when it matters, rather than letting someone find out:

- **No reconciliation.** Ownership is by id and that is the whole of it. There is no merge, no
  rebase, no conflict resolution, and none is planned here.
- **No bindings.** Arrows are free-floating geometry.
- **No multi-user sync.** One board, one operator, one agent.
- **A push re-renders the whole page.** Pushing the same path again is what refreshes an
  ordinary canvas — on a board, prefer rewriting the document and letting the update channel
  carry it, which is what keeps the drawing.
- **An appearance flip reloads the page.** helm reloads a canvas outright when the pane switches
  light/dark, and the board reloads from your document. The operator's own records are cached in
  the page's `localStorage` and restored, so a reload does not lose them — but that cache is the
  page's, not a file, and it is per artifact name.
- **What is drawn reaches you on your next turn, never sooner.**

## Checking it yourself

`board-core.js` holds every decision the board makes — the ownership diff, the overlap ranking,
the report — as functions over plain values, and `bash .claude/skills/helm-board/test.sh` runs
them in node. Run it after touching anything here.

What no test reaches: that a real trackpad stroke crosses AppKit → WebKit into quickdraw. The
spike closed that leg once, by the operator's own hand, and it is his to repeat — a synthetic
pointer event is produced inside the page and never crosses that boundary, which is exactly what
`pressure.varies` is the discriminator for.

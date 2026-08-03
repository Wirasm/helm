---
name: helm-canvas
description: Offer an artifact to the operator as a helm canvas — a rendered markdown or HTML file they open with ⌘-click. Use after writing a plan, report, review, diagram, or interactive page that is worth looking at rather than reading in a terminal; when the operator says "open it in the canvas", "show me that", "render this", "put it on screen"; when about to paste something long into the terminal instead; or via /helm-canvas.
---

# Offer a canvas

**helm is the macOS terminal application this session is running inside.** Not a library, not a
dependency, and not something in the repository you are working in — you could be in any repo and
still be in helm. Nothing in the current project needs to know about it, and you will not find it
there. Do not go looking.

helm renders a markdown or HTML file as a **canvas** — a pane beside the terminal. You put
something there by writing a file and printing a link to it. The operator ⌘-clicks the link.

**You cannot open a canvas yourself, and must not try.** You offer; they decide. That is helm's
rule, not a limitation to route around.

## How

Write the file, then print an OSC 8 hyperlink to it:

```bash
printf '\e]8;;file://%s\e\\%s\e]8;;\e\\\n' "$ABSOLUTE_PATH" "$LINK_TEXT"
```

- The path must be **absolute** and the URL must be `file://`.
- Only **`.md` `.markdown` `.mdown` `.html` `.htm`** open in a canvas. Anything else is handed to
  the system — helm decides by extension alone, without reading the file.
- Artifacts go in this project's `~/.prp/<key>/` store, **never in the repo**.

## When to offer

Offer something worth *looking at*: a plan, a review, a report, a diagram, an interactive page.

Do not offer a three-line answer — say it. Offering everything is as useless as offering nothing,
and the operator learns to ignore the links.

If you are about to paste something long into the terminal, that is the signal to write a file
and offer it instead.

## Two things that will bite

**Do not write into a canvas the operator has marked up.** When they annotate one, helm writes
their notes to a file *beside* the artifact rather than into it — precisely because you rewrite
the artifact and would clobber anything kept inside. That is helm's behaviour, not a convention
you set up or go looking for: read the notes if they appear, and only ever write the artifact.

**Mermaid node ids are not stable across renders yet** (helm #113). A diagram meant to be
annotated will hand back an anchor that has already changed. Until that lands, prefer HTML with
your own ids when the operator needs to point at parts of it.

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

Write the file, then print an OSC 8 hyperlink to it **and the plain path on the line after**:

```bash
printf '\e]8;;file://%s\e\\%s\e]8;;\e\\\n' "$ABSOLUTE_PATH" "$LINK_TEXT"
printf '%s\n' "$ABSOLUTE_PATH"
```

- The path must be **absolute** and the URL must be `file://`.
- Only **`.md` `.markdown` `.mdown` `.html` `.htm`** open in a canvas. Anything else is handed to
  the system — helm decides by extension alone, without reading the file.
- Artifacts go in this project's `~/.prp/<key>/` store, **never in the repo**.

**Print the plain path too, and do not skip it.** ⌘-click does not currently reach helm from
inside a TUI — the agent's own terminal UI captures the mouse before helm sees it (helm #124). The
bare path is what the operator can actually act on today. Treat the hyperlink as the thing that
will work once #124 lands, and the path as the thing that works now.

## Check it before you offer it

**For an `.html` artifact, look at it first.** You wrote it; you can render it. Nothing in helm has
to help you, and you should not ask it to.

This works because a canvas is **self-contained** — an `.html` artifact carries everything it
needs, so the file you render is the page the operator sees. That is a helm rule rather than a
coincidence, and it is what makes checking your own work possible at all.

Render the file the way you would check any local page — a headless browser, a screenshot,
whatever this environment already has — and look for:

- **Did it render at all**, or is it a blank page? An unclosed tag is invisible in the source and
  total on screen.
- **Did the diagrams parse?** A malformed mermaid fence renders as an error box, not as a diagram.
  You cannot tell from your own source that it failed.
- **Is anything you intended missing** — a section that collapsed, a table that came out as text.

Fix it, then offer it. Offering a broken page and letting the operator find it is the failure this
step exists to prevent.

**A markdown canvas cannot be checked this way, and you should not try.** For `.md`, **helm is the
renderer**: it converts the markdown, renders the mermaid fences, and applies its own type scale.
Opening the `.md` yourself shows you raw markdown, not the canvas. There is no way for you to see a
markdown canvas as the operator sees it — so when the *appearance* is what matters, prefer `.html`,
which you can verify.

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

**A mermaid node can be annotated, but only in some diagram families.** helm hands back the
identifier that appears in your ```mermaid fence — name a node `phase2` and the operator's mark
comes back as `phase2`, which you can grep for and edit (helm #113).

That holds for **flowchart, class, state and er** diagrams, and only those. `mindmap` and
`sequenceDiagram` put no author-written identifier in the rendered output at all, so a mark on one
degrades to quoted text with nothing to anchor to; `gitGraph` and `pie` produce no addressable
nodes whatsoever. **If the operator needs to point at parts of a diagram, use a flowchart** — or
HTML with your own ids.

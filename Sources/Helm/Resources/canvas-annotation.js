(function () {
  if (!window.webkit || !window.webkit.messageHandlers
      || !window.webkit.messageHandlers.helmCanvas) { return; }
  var bridge = window.webkit.messageHandlers.helmCanvas;
  if (!window.__helmMarkTool) { window.__helmMarkTool = "select"; }
  function tool() { return window.__helmMarkTool || "select"; }

  // helm's own document wrapper — helm's chrome, marked as such by the Swift that writes it,
  // exactly as the ink layer is.
  //
  // `CanvasHTML.documentPage` puts every rendered markdown artifact inside
  // `<article id="content" data-helm-frame>`, so `#content` is an id helm wrote and no
  // operator's `.md` file contains. An anchor naming it is a grep that finds nothing, printed
  // in exactly the form that means "grep for this", which is #215's second half: a degradation
  // that announced itself would be fine, and this one asserts.
  //
  // The same judgement `MermaidAnchor.isRenderGenerated` makes on the Swift side, for the same
  // reason — an id minted by the renderer rather than authored is not an anchor.
  //
  // **Why a marker and not a look at the wrapper itself.** The first cut recognised the frame
  // by its id and its position directly under the body, which is true by construction of the
  // page above — and equally true of an agent-authored wrapper using the same landmark id,
  // which is among the commonest in hand-written HTML. **This script does not only meet helm's
  // generated page**: an `.html` artifact is read straight from disk (`CanvasFileViews`, "the
  // artifact IS the document here"), never passes through `documentPage`, and gets this same
  // script — so that guess silently discarded an id the agent really did write and really
  // could grep for, and did it indistinguishably from a block that has no id at all. An
  // attribute helm itself writes cannot be wrong in either direction.
  //
  // Spelled out here rather than interpolated, exactly like the handler name and the tool
  // global above, and held to `CanvasHTML.documentPage` by
  // `CanvasAnchorTests.testTheScriptAndTheGeneratedPageStillAgreeOnHelmsWrapper`: JavaScript
  // cannot compile against a Swift constant, so the gate is a test that reads both halves.
  //
  // An attribute and never `tagName` — a browser reports `ARTICLE` where the test stub reports
  // `article`, and a comparison that holds in the harness and not in WebKit is the failure
  // that suite exists to prevent.
  function helmFrame(node) {
    return node.getAttribute("data-helm-frame") !== null;
  }

  // What the operator marked, and what it can be NAMED by — two questions, and #215 was
  // conflating them into one field. `text` is the marked element's own; `id` may come from
  // an ancestor, because a name can belong to a container and still name what is inside it.
  //
  // The old code reassigned `node` while walking and then read the text off whatever the
  // walk stopped on, so `text` was always the ANCESTOR's: `node || labelled` could not fall
  // back, since after the walk `node` is either the id-bearing ancestor or `document.body`
  // and both are truthy. Every markdown block came back as the whole document under
  // `#content`, and every id-less sibling produced the identical `(id, text)` pair — which
  // is why circling three paragraphs yielded one target. Per-element text separates them
  // with no change to the dedupe key.
  //
  // **The walk stays.** It is what lets a marked word inside `<h2 id="phase-2">` anchor to
  // the heading, and it is the whole of #113: a hit on a mermaid node lands on the `<text>`
  // or `<p>` inside the `<g>` that carries the id, so a resolver that read only the marked
  // element's own id would anchor no diagram at all.
  //
  // ONE name for one element, and now genuinely one: the text-selection branch below used to
  // carry a second copy of this walk, so "every tool resolves the same way" was true of three
  // tools out of four and a selection on a markdown canvas anchored to `#content` through a
  // code path `resolve` never touched.
  function nameFor(node) {
    for (var up = node; up && up !== document.body; up = up.parentNode) {
      if (up.id && !helmFrame(up)) { return up.id; }
    }
    return null;
  }

  // The element a gesture is really about. A Range's `commonAncestorContainer` is very often
  // a TEXT node — it is whatever the highlight happens to sit inside — and a text node carries
  // no id and is not what a mark names, so step up to the element holding it. Null for a node
  // detached from the document, which is why both callers check before dereferencing; reading
  // `.textContent` off that null used to throw.
  function elementFor(node) {
    return node && node.nodeType === 3 ? node.parentNode : node;
  }

  // ONE resolver, used by every tool — #112 asks for the draw-time hit test and any later
  // re-resolution to share a code path, because inconsistent resolution between capture and
  // action is its own bug class. So this changes what all four marks report, not one.
  function resolve(node) {
    node = elementFor(node);
    if (!node) { return null; }
    var text = (node.textContent || "").trim().slice(0, 400);
    if (!text) { return null; }
    return { id: nameFor(node), text: text };
  }

  function targetAt(x, y) {
    if (paper) { paper.style.display = "none"; }
    var hit = document.elementFromPoint(x, y);
    if (paper) { paper.style.display = ""; }
    return resolve(hit);
  }

  // Ray casting. A freehand loop is treated as closed, because a person circling
  // something does not carefully meet the ends and helm should not make them.
  function inside(poly, x, y) {
    var yes = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      var xi = poly[i].x, yi = poly[i].y, xj = poly[j].x, yj = poly[j].y;
      if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) {
        yes = !yes;
      }
    }
    return yes;
  }

  // Everything the loop encircles — an element is a target when the loop covers most of IT.
  //
  // Not "the loop contains its centre", which is the rule this replaces and the defect in
  // #208. Centre-testing is a good defence against a SIBLING the stroke grazed, and no defence
  // at all against an ANCESTOR: <article id="content"> wraps the whole page, so its centre IS
  // the page's centre, and every loop drawn near the middle of a document also returned the
  // entire document — listed first, in document order, with a 400-character quote of mermaid's
  // injected CSS behind it.
  //
  // Coverage is asymmetric, and that asymmetry is the whole fix: an element larger than the
  // loop cannot have most of itself inside the loop, wherever its centre falls. A container the
  // operator really did circle still qualifies, because then the loop is around it. Measured on
  // the page #208 was found on, for a loop around one node: that node covers 1.00, the <svg>
  // around it 0.08, the <article> around that 0.02.
  //
  // **That guarantee does not depend on the stroke's shape**, which is what makes it a fix
  // rather than a heuristic. An element's coverage is bounded above by the loop's own interior
  // area divided by the element's, so an element far larger than the loop cannot qualify
  // however the loop is drawn — on the page above that ceiling was 1.4%.
  //
  // **What dropping the centre test gave up, stated exactly.** For a CONVEX stroke, covering
  // more than half of a rectangle implies containing its centre: a half-plane holding more than
  // half of a rectangle holds its centre, and a stroke excluding the centre could be separated
  // from it by one. There the centre test was implied and dropping it changes nothing. But a
  // freehand stroke is NOT guaranteed convex — a hand dipping around an indent draws a concave
  // one, and `inside` accepts any path at all. Measured: a horseshoe notched across the mid-row
  // of a 100x100 box covers 0.918 of it while its centre falls in the notch. So for a concave
  // stroke this WIDENS what a loop selects, taking something the centre test would have
  // rejected. That is what the rule says on its face — the loop does cover most of it — and it
  // cannot let an ancestor back in, because the bound above holds whatever the shape.
  //
  // A grazed neighbour is rejected harder than before either way, by covering almost none of
  // itself rather than by where its centre happened to be.
  //
  // The grid is sample DENSITY and carries no invariant: "more than half" is counted in
  // integers below, so the comparison is exact at any density and a tie — exactly half —
  // is rejected. Nothing here has to be kept odd, or kept anything.
  var grid = 7;

  // How many of `box`'s sample points the loop contains, on a grid of cell centres. Sampled
  // rather than clipped: the stroke is a path of any shape, and exact polygon clipping is a
  // great deal of code to move a decision whose two sides measure an order of magnitude apart.
  function covered(poly, box) {
    var hits = 0;
    for (var i = 0; i < grid; i++) {
      for (var j = 0; j < grid; j++) {
        var x = box.x + (box.width * (i + 0.5)) / grid;
        var y = box.y + (box.height * (j + 0.5)) / grid;
        if (inside(poly, x, y)) { hits++; }
      }
    }
    return hits;
  }

  function targetsInside(poly) {
    var seen = {}, found = [];
    var nodes = document.querySelectorAll("[id], p, li, td, th, h1, h2, h3");
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].closest("[data-helm-mark]")) { continue; }
      var r = nodes[i].getBoundingClientRect();
      if (!r.width && !r.height) { continue; }
      // getBoundingClientRect is viewport-relative; the stroke is page-relative.
      var box = {
        x: r.left + window.scrollX, y: r.top + window.scrollY,
        width: r.width, height: r.height
      };
      // More than half, in integers: one half is not a tuning parameter, it is the number the
      // convex argument above needs, so it is spelled as a comparison rather than a constant.
      if (2 * covered(poly, box) <= grid * grid) { continue; }
      var t = resolve(nodes[i]);
      if (!t) { continue; }
      var key = (t.id || "") + "\u0000" + t.text;
      if (seen[key]) { continue; }
      seen[key] = true;
      found.push(t);
    }
    return found;
  }

  // The ink. helm's own chrome, marked as such so an agent reading the DOM can tell
  // it from what it authored, and inert so the page can never come to need it.
  var paper = null, ink = null, stroke = [], from = null;
  // Has this mark been POSTED? Until it has, the ink is an in-flight gesture and
  // anything that interrupts may throw it away. Once posted it is the comment
  // field's subject, and only Swift — closing that field — may take it down.
  var committed = false;

  function sheet() {
    if (paper) { return paper; }
    paper = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    paper.setAttribute("data-helm-mark", "");
    // Sized once, from the document as it is now. A late-loading image or a window
    // resize can therefore leave the ink adrift from what it circled — accepted,
    // because the ANCHOR is an id or a quote and never these pixels. The ink is a
    // reminder of what you marked, not the record of it.
    //
    // ABSOLUTE over the whole document, not fixed over the viewport. A mark is
    // glued to what it was drawn around: scroll away and it travels off screen with
    // its subject, scroll back and it is still there. Fixed positioning would leave
    // it hanging over whatever scrolled underneath, which is a mark that lies.
    paper.style.cssText =
      "position:absolute;left:0;top:0;" +
      "width:" + document.documentElement.scrollWidth + "px;" +
      "height:" + document.documentElement.scrollHeight + "px;" +
      "pointer-events:none;z-index:2147483647;overflow:visible";
    // The arrowhead `marker-end` points at. An unresolvable url() is IGNORED rather
    // than erroring, so without this the arrow tool silently drew a bare line — the
    // one cue that tells it apart from freehand while you are drawing.
    //
    // Built with DOM calls rather than a markup string: this script reads and
    // reports and never writes markup, which is an invariant with a test on it, and
    // a markup string here is the shape that quietly becomes an injection vector.
    var svgNS = "http://www.w3.org/2000/svg";
    var defs = document.createElementNS(svgNS, "defs");
    var marker = document.createElementNS(svgNS, "marker");
    marker.setAttribute("id", "helm-mark-head");
    marker.setAttribute("markerWidth", "8");
    marker.setAttribute("markerHeight", "8");
    marker.setAttribute("refX", "6");
    marker.setAttribute("refY", "3");
    marker.setAttribute("orient", "auto");
    var barb = document.createElementNS(svgNS, "path");
    barb.setAttribute("d", "M0,0 L6,3 L0,6 Z");
    barb.setAttribute("fill", "currentColor");
    marker.appendChild(barb);
    defs.appendChild(marker);
    paper.appendChild(defs);
    document.body.appendChild(paper);
    return paper;
  }

  function draw(d, head) {
    var svg = sheet();
    if (!ink) {
      ink = document.createElementNS("http://www.w3.org/2000/svg", "path");
      ink.setAttribute("fill", "none");
      ink.setAttribute("stroke", "currentColor");
      ink.setAttribute("stroke-width", "2.5");
      ink.setAttribute("stroke-linecap", "round");
      ink.setAttribute("stroke-linejoin", "round");
      ink.setAttribute("opacity", "0.85");
      if (head) { ink.setAttribute("marker-end", "url(#helm-mark-head)"); }
      svg.appendChild(ink);
    }
    ink.setAttribute("d", d);
  }

  function ring(x, y) {
    var svg = sheet();
    var dot = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    dot.setAttribute("cx", x); dot.setAttribute("cy", y); dot.setAttribute("r", "13");
    dot.setAttribute("fill", "none");
    dot.setAttribute("stroke", "currentColor");
    dot.setAttribute("stroke-width", "2.5");
    dot.setAttribute("opacity", "0.85");
    svg.appendChild(dot);
  }

  function wipe() {
    if (paper && paper.parentNode) { paper.parentNode.removeChild(paper); }
    paper = null; ink = null; stroke = []; from = null; committed = false;
  }

  // Throw away an in-flight gesture, and ONLY an in-flight one.
  //
  // A drag released outside the document — over helm's own header, another pane —
  // never fires mouseup here, and the ink would sit at max z-index until the next
  // stroke. But `blur` also fires when the comment field takes the keyboard, which
  // it does the instant it appears: an unconditional wipe there erases the mark
  // before the operator has looked at it, which is the whole feature.
  function abandon() { if (!committed) { wipe(); } }

  window.addEventListener("blur", abandon);
  document.addEventListener("mouseleave", abandon);
  // Swift closing the comment field — the only thing allowed to remove a posted mark.
  window.__helmWipeMark = wipe;
  // A tool change, which must not disturb a mark already awaiting its comment.
  window.__helmAbandonMark = abandon;

  function pathFrom(points) {
    var d = "M" + points[0].x + " " + points[0].y;
    for (var i = 1; i < points.length; i++) {
      d += " L" + points[i].x + " " + points[i].y;
    }
    return d;
  }

  // The stroke is in PAGE coordinates so it scrolls with its subject. The rect that
  // travels to Swift is not: it places the comment field on screen, so it has to be
  // viewport-relative or the field lands off screen the moment the page is scrolled.
  function viewportRect(box) {
    return {
      x: box.x - window.scrollX, y: box.y - window.scrollY,
      width: box.width, height: box.height
    };
  }

  function bounds(points) {
    var l = Infinity, r = -Infinity, t = Infinity, b = -Infinity;
    for (var i = 0; i < points.length; i++) {
      l = Math.min(l, points[i].x); r = Math.max(r, points[i].x);
      t = Math.min(t, points[i].y); b = Math.max(b, points[i].y);
    }
    return { x: l, y: t, width: r - l, height: b - t };
  }

  document.addEventListener("mousedown", function (e) {
    var t = tool();
    if (t === "select") { return; }
    // Primary button only. A tool is a STICKY selection, unlike the modifier it
    // replaced — so a right-click for the page's own context menu would otherwise
    // start a stroke, and the menu's tracking loop eats the matching mouseup.
    if (e.button !== 0) { return; }
    e.preventDefault();
    wipe();
    // Page coordinates, so the stroke means the same thing after a scroll.
    stroke = [{ x: e.pageX, y: e.pageY }];
    from = targetAt(e.clientX, e.clientY);
  }, true);

  document.addEventListener("mousemove", function (e) {
    if (!stroke.length) { return; }
    var t = tool();
    if (t === "point") { return; }
    stroke.push({ x: e.pageX, y: e.pageY });
    if (t === "arrow") {
      draw(pathFrom([stroke[0], stroke[stroke.length - 1]]), true);
    } else {
      draw(pathFrom(stroke), false);
    }
  }, true);

  document.addEventListener("mouseup", function (e) {
    var t = tool();

    if (t === "select") {
      // The text is the operator's own highlight rather than an element's contents, which is
      // why this branch cannot simply call `resolve` — but the NAME is the same question the
      // other three tools ask, so it goes through the same `nameFor` (#215).
      var selection = document.getSelection();
      var empty = !selection || selection.isCollapsed || selection.rangeCount === 0;
      var text = empty ? "" : String(selection).trim();
      if (!text) { bridge.postMessage({ cleared: true }); return; }
      var range = selection.getRangeAt(0);
      var node = elementFor(range.commonAncestorContainer);
      var id = node ? nameFor(node) : null;
      var r = range.getBoundingClientRect();
      bridge.postMessage({
        id: id, text: text,
        rect: { x: r.left, y: r.top, width: r.width, height: r.height }
      });
      return;
    }

    if (!stroke.length) { return; }
    var startTarget = from;
    var box = bounds(stroke.concat([{ x: e.pageX, y: e.pageY }]));
    var drawn = stroke.slice();
    // The ink STAYS. It is the comment field's subject, and a field floating with
    // nothing on screen saying what it is about is the gap this closes. Swift takes
    // it down when the field closes; a new stroke replaces it.
    stroke = []; from = null;

    if (t === "point") {
      var at = targetAt(e.clientX, e.clientY);
      if (!at) { wipe(); bridge.postMessage({ cleared: true }); return; }
      // A tap draws nothing on its way, so it needs a mark of its own — otherwise
      // the one gesture with no travel is also the one with no visible subject.
      ring(e.pageX, e.pageY);
      committed = true;
      bridge.postMessage({
        mark: "point", id: at.id, text: at.text, rect: viewportRect(box)
      });
      return;
    }

    if (t === "arrow") {
      draw(pathFrom([drawn[0], { x: e.pageX, y: e.pageY }]), true);
      var end = targetAt(e.clientX, e.clientY);
      // Either end may be empty — an arrow into blank space is "add a node here".
      committed = true;
      bridge.postMessage({
        mark: "relation", from: startTarget, to: end, rect: viewportRect(box)
      });
      return;
    }

    if (t === "freehand") {
      draw(pathFrom(drawn), false);
      // What the loop encircles. Posted even when empty, so decode refuses it
      // visibly — silence is indistinguishable from the stroke never registering.
      committed = true;
      bridge.postMessage({
        mark: "enclosure", targets: targetsInside(drawn), rect: viewportRect(box)
      });
      return;
    }

    // A tool helm does not know. Do nothing rather than guess — freehand used to be
    // the fall-through here, so a garbage token silently drew a circle.
  }, true);
})();

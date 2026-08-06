(function () {
  if (!window.webkit || !window.webkit.messageHandlers
      || !window.webkit.messageHandlers.helmCanvas) { return; }
  var bridge = window.webkit.messageHandlers.helmCanvas;
  if (!window.__helmMarkTool) { window.__helmMarkTool = "select"; }
  function tool() { return window.__helmMarkTool || "select"; }

  // The nearest ancestor carrying an id, and the text it covers. ONE resolver, used
  // by every tool — #112 asks for the draw-time hit test and any later re-resolution
  // to share a code path, because inconsistent resolution between capture and action
  // is its own bug class.
  function resolve(node) {
    if (!node) { return null; }
    if (node.nodeType === 3) { node = node.parentNode; }
    var labelled = node;
    var id = null;
    while (node && node !== document.body) {
      if (node.id) { id = node.id; break; }
      node = node.parentNode;
    }
    var text = ((node || labelled).textContent || "").trim().slice(0, 400);
    if (!text) { return null; }
    return { id: id, text: text };
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

  // Everything the loop encircles, by CENTRE rather than by any overlap: a stroke
  // that grazes a neighbour did not mean the neighbour.
  function targetsInside(poly) {
    var seen = {}, found = [];
    var nodes = document.querySelectorAll("[id], p, li, td, th, h1, h2, h3");
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].closest("[data-helm-mark]")) { continue; }
      var r = nodes[i].getBoundingClientRect();
      if (!r.width && !r.height) { continue; }
      // getBoundingClientRect is viewport-relative; the stroke is page-relative.
      var cx = r.left + r.width / 2 + window.scrollX;
      var cy = r.top + r.height / 2 + window.scrollY;
      if (!inside(poly, cx, cy)) { continue; }
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
      // Unchanged: the text selection helm has always reported.
      var selection = document.getSelection();
      var empty = !selection || selection.isCollapsed || selection.rangeCount === 0;
      var text = empty ? "" : String(selection).trim();
      if (!text) { bridge.postMessage({ cleared: true }); return; }
      var range = selection.getRangeAt(0);
      var node = range.commonAncestorContainer;
      if (node.nodeType === 3) { node = node.parentNode; }
      var id = null;
      while (node && node !== document.body) {
        if (node.id) { id = node.id; break; }
        node = node.parentNode;
      }
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

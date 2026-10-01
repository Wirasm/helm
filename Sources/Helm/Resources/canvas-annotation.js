(function () {
  if (!window.webkit || !window.webkit.messageHandlers
      || !window.webkit.messageHandlers.helmCanvas) { return; }
  var bridge = window.webkit.messageHandlers.helmCanvas;
  // `read` is the default, and it is a real tool rather than the absence of one (#302). The
  // case it replaces was called `select` and did two jobs: reading the page, and treating what
  // you highlighted as the subject of a comment. So a canvas was never inert — every click was
  // a candidate mark — and `CanvasMarkTool`'s header has the argument. `text` is the second
  // job, and the operator picks it up. (Freehand, arrow and point tools stood beside it until
  // #385 removed them; the board is where the operator draws.)
  if (!window.__helmMarkTool) { window.__helmMarkTool = "read"; }
  function tool() { return window.__helmMarkTool || "read"; }

  // What a text mark is painted with, pushed by Swift beside the tool itself.
  //
  // **A palette token, resolved in Swift**, because the two halves of one are not a thing a
  // page can pick between: `Palette.helm.selection` is "what a selection leaves behind", it has
  // a light value and a dark one, and which is in force is helm's effective appearance — not
  // the system's, which is what a `prefers-color-scheme` rule here would have followed and got
  // wrong for anyone using helm's own appearance override. `CanvasHTML.markTint` is the one
  // spelling; there is deliberately no literal colour anywhere in this file.
  //
  // **It cannot be missing when it is needed**, which is why nothing here falls back to a
  // colour of its own. It rides `setMarkTool`, so the only way it is unset is that the tool
  // push never landed — and then the page is still on `read`, which paints nothing at all.
  function tint() {
    return typeof window.__helmMarkTint === "string" ? window.__helmMarkTint : null;
  }

  // EVERY message posted below carries `kind`, and it is the ONLY field that says what the
  // message is (#109/#210). There were three shapes here and no declared kind: a selection was
  // "has a non-empty top-level text", a dismissal was `{cleared:true}`, and a geometry mark was
  // `{mark:"…"}` — so the Swift gate had to infer the shape, inferred it wrongly, and dropped
  // every geometry mark for months (#216). The page posts two kinds now: `selection` and
  // `cleared`.
  //
  // The far side is `CanvasPageSelection.Kind` in `CanvasFileViews.swift`, which is exhaustive
  // and REFUSES a kind it does not know rather than guessing at the shape. So a kind added here
  // and not there is dropped loudly (an NSLog naming it), and
  // `CanvasAnnotationScriptTests.testTheScriptAndSwiftStillAgreeOnEveryMessageKind` fails: a
  // JavaScript file cannot compile against a Swift enum, so that test is the gate.

  // A marked wrapper distinguishes helm's shell from an authored id="content".
  function helmFrame(node) {
    return node.getAttribute("data-helm-frame") !== null;
  }

  // A region the PAGE owns the pointer in — `data-helm-surface`, declared by the artifact
  // (#111). Inside one, helm does nothing at all: no mark, no `cleared`, and no anchor resolved
  // out of it.
  //
  // Spelled out here rather than interpolated, exactly like the handler name, the tool global
  // and `data-helm-frame` above. `CanvasSurface` in Swift is where the argument lives — why the
  // page rather than helm writes this one, and why helm's marks are strictly worse on a board
  // than the board's own — and `CanvasSurfaceTests` is the gate over all three copies of the string,
  // this one included, because a JavaScript file cannot compile against a Swift constant.
  //
  // `closest`, not a hand-rolled walk. Null-tolerant because `e.target` is null for a
  // gesture over nothing at all, and that must not throw.
  function inPageSurface(node) {
    return !!(node && node.closest && node.closest("[data-helm-surface]"));
  }

  // Diagram provenance must be known before an id leaves the DOM. In particular,
  // actor0 is renderer bookkeeping inside Mermaid and an authored name outside it.
  function anchorFor(node, text) {
    if (node && node.closest && node.closest(".mermaid")) {
      for (var up = node; up && up !== document.body; up = up.parentNode) {
        if (up.id) {
          return { anchorKind: "mermaid", id: up.id,
                   elementClass: up.getAttribute("class") || "" };
        }
      }
      return { anchorKind: "mermaid", id: null };
    }
    var source = null;
    for (var up = node; up && up !== document.body; up = up.parentNode) {
      if (up.id && !helmFrame(up)) { return { anchorKind: "element", id: up.id }; }
      if (source === null) { source = up.getAttribute("data-helm-source"); }
      if (helmFrame(up)) {
        if (source !== null) {
          try { return { anchorKind: "excerpt", source: JSON.parse(source), id: null }; }
          catch (error) {
            return { anchorKind: "unanchored", id: null, reason: "the source metadata is malformed" };
          }
        }
        return { anchorKind: "unanchored", id: null,
                 reason: "no literal source block covers this selection; select one Markdown block" };
      }
    }
    return { anchorKind: "unanchored", id: null,
             reason: "this HTML selection has no authored id; add an id to its block" };
  }

  // The element a gesture is really about. A Range's `commonAncestorContainer` is very often
  // a TEXT node — it is whatever the highlight happens to sit inside — and a text node carries
  // no id and is not what a mark names, so step up to the element holding it. Null for a node
  // detached from the document, which is why the caller checks before naming it.
  function elementFor(node) {
    return node && node.nodeType === 3 ? node.parentNode : node;
  }

  // The text mark, painted (#308).
  //
  // A text mark was once the browser's own selection, which greys the instant the comment
  // field takes the keyboard, so the operator was asked to comment on a passage that no longer
  // looked marked.
  //
  // **A CSS Custom Highlight, not a rectangle over the page**, and the reason is anchoring.
  // An anchor is resolved out of the DOM — `anchorFor` reads source identity from ancestors, and a range's
  // `commonAncestorContainer` decides which element it is about — so a highlight that wrapped
  // the range in elements of its own, or split its text nodes, would change the thing the mark
  // is named by while claiming to change nothing. `CSS.highlights` mutates **no DOM at all**:
  // no wrapper, no split, no attribute, not one node added to the artifact's tree. Rects over
  // the page would also have avoided that, and would have had to be translucent and sit over
  // the glyphs at max z-index, frozen at the geometry the range had when it was marked. This
  // paints behind the text the way the browser's own selection does, and reflows with it.
  //
  // **Measured in a real WKWebView from the bridge world before any of this was written**,
  // because none of it survives being assumed across a content-world boundary: `CSS.highlights`
  // and `Highlight` exist there; a highlight `set` from the isolated world is visible to the
  // PAGE world, so it is the document's one registry the renderer reads rather than a per-world
  // copy; and a constructed stylesheet adopted from the isolated world parses its
  // `::highlight()` rule. `CanvasMarkReachesAgentLiveTests` is that measurement kept as a gate.
  //
  // Spelled out here rather than interpolated, exactly like the handler name, the tool global,
  // `data-helm-frame` and `data-helm-surface`. `CanvasHTML.markHighlightName` is the far half
  // and `CanvasAnnotationScriptTests` holds them together, since a JavaScript file cannot
  // compile against a Swift constant.
  var highlightName = "helm-mark";
  var tintSheet = null;

  // The `::highlight()` rule the registry has nothing to paint with until it exists.
  //
  // **Adopted, not appended.** `document.adoptedStyleSheets` adds no node to the tree, so an
  // agent reading the artifact's DOM back sees exactly what it wrote. A `<style>` in `<head>`
  // would render identically and would be an element helm put into someone else's document.
  //
  // Re-checked and re-written on every paint rather than built once: `adoptedStyleSheets` is
  // the document's, an artifact's own script may replace it wholesale, and a registered
  // highlight with no rule to paint it is indistinguishable from no mark at all.
  //
  // Returns false when the browser has neither, which is the same graceful nothing a missing
  // script is (#33) — the canvas still renders and the mark still reaches the agent, because
  // the payload is the anchor and never these pixels.
  function adoptTint(colour) {
    if (typeof window.CSSStyleSheet !== "function") { return false; }
    if (!document.adoptedStyleSheets) { return false; }
    if (!tintSheet) { tintSheet = new window.CSSStyleSheet(); }
    tintSheet.replaceSync(
      "::highlight(" + highlightName + "){background-color:" + colour + "}");
    if (document.adoptedStyleSheets.indexOf(tintSheet) < 0) {
      document.adoptedStyleSheets = document.adoptedStyleSheets.concat([tintSheet]);
    }
    return true;
  }

  // **`cloneRange()`, and that is the whole feature rather than a tidiness.** `getRangeAt`
  // hands back a range the Selection still owns, and the native selection goes away the moment
  // the comment field takes the keyboard — which is the exact moment this has to survive. The
  // clone is the operator's mark; the original is the browser's selection, and they stop being
  // the same thing one keystroke later.
  function paintTextMark(range) {
    var colour = tint();
    if (!colour) { return false; }
    if (!window.CSS || !window.CSS.highlights) { return false; }
    if (typeof window.Highlight !== "function") { return false; }
    if (!adoptTint(colour)) { return false; }
    window.CSS.highlights.set(highlightName, new window.Highlight(range.cloneRange()));
    return true;
  }

  function unpaintTextMark() {
    if (window.CSS && window.CSS.highlights) {
      window.CSS.highlights.delete(highlightName);
    }
  }

  // Swift closing the comment field — posted, dismissed by the ✕, or by Escape — is the only
  // thing that takes a posted mark down.
  window.__helmWipeMark = unpaintTextMark;

  document.addEventListener("mouseup", function (e) {
    var t = tool();

    // **Reading, and helm says nothing whatsoever** (#302). Not a quieter mark — no
    // `selection`, no `cleared`, no comment field, no message of any kind. Text still
    // highlights, because the browser does that, and helm simply does not read the result.
    //
    // **`cleared` is deliberately not sent here, and that is a decision rather than a
    // consequence.** It is the canvas's click-elsewhere-to-dismiss (#165), and under `read`
    // there is nothing to dismiss: no mark can be in flight, because no gesture under this
    // tool ever posted one. Swift answers a `cleared` by closing the notes drawer as well
    // (`CanvasModel.pageDidReport`), so sending one anyway would mean a canvas nobody is
    // marking on still closing the operator's drawer every time they clicked the page —
    // which is the same complaint as the popup, one surface over. The drawer keeps its own
    // exits: its button, and Escape.
    if (t !== "text") { return; }

    // **The page's pointer, so helm has nothing to say about this click** (#111). Without
    // this, a drag on a drawable board with this tool held selects no text, so the branch
    // below posts `cleared` — and helm answers a dismissal by taking the operator's selection
    // down and closing the notes drawer. Every stroke closed their notes. Silence is the
    // correct message here: nothing helm can name was marked, and `cleared` does not mean
    // "nothing happened", it means "the operator clicked away from a selection".
    //
    // **Still needed, and #302 did not subsume it.** `read` is a GLOBAL mode the operator
    // holds; `data-helm-surface` is a PER-ARTIFACT declaration that binds whatever they are
    // holding. Delete this and a board is broken again the moment anyone picks up the text
    // tool.
    if (inPageSurface(e.target)) { return; }
    // The text is the operator's own highlight rather than an element's contents; the NAME
    // comes from `anchorFor` (#195).
    var selection = document.getSelection();
    var empty = !selection || selection.isCollapsed || selection.rangeCount === 0;
    var text = empty ? "" : String(selection).trim();
    // Take the mark down here rather than waiting to be told. Swift answers a `cleared` by
    // closing the field, which comes back as a wipe — but a render later, and in between the
    // operator would be looking at a highlight over the passage they just clicked away from.
    if (!text) { unpaintTextMark(); bridge.postMessage({ kind: "cleared" }); return; }
    var range = selection.getRangeAt(0);
    var node = elementFor(range.commonAncestorContainer);
    var anchor = anchorFor(node, text);
    var r = range.getBoundingClientRect();
    // One mark on screen: whatever was up before comes down first, even when this one cannot
    // be painted. The new mark then STAYS — from here it is the comment field's subject, and
    // only Swift closing that field may take it down.
    unpaintTextMark();
    paintTextMark(range);
    bridge.postMessage(Object.assign({
      kind: "selection", text: text,
      rect: { x: r.left, y: r.top, width: r.width, height: r.height }
    }, anchor));
  }, true);
})();

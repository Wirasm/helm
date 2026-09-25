// A DOM small enough to read, and real enough to RUN helm's annotation script against.
//
// This is a test harness, not a browser. It implements exactly what
// `Sources/Helm/Resources/canvas-annotation.js` touches and nothing else, so the script under
// test is the shipped file — the same bytes `CanvasHTML.annotationScript()` hands WebKit —
// rather than a string an assertion looked at. `CanvasScriptRuntime` loads this first, the
// script second, and drives gestures through `__helm`.
//
// Two places where a browser and a stub could differ, decided deliberately:
//
//   - `getBoundingClientRect` is VIEWPORT-relative and boxes are stored in page coordinates,
//     exactly as the real thing behaves (#196 lived in that gap).
//   - A mouse event's `target` is the topmost element under the pointer. It is load-bearing
//     for #111: the whole of `data-helm-surface` is a `closest` walk from `e.target`.
(function (global) {
  "use strict";

  function box(x, y, width, height) {
    return { x: x, y: y, width: width, height: height };
  }

  function Element(tag) {
    this.tagName = tag;
    this.nodeType = 1;
    this.parentNode = null;
    this.childNodes = [];
    this.attributes = {};
    this.id = "";
    this.style = { cssText: "", display: "" };
    this.ownText = "";
    // Page coordinates, or null for "not laid out" — which is what a `<defs>` subtree is.
    this.box = null;
  }

  Object.defineProperty(Element.prototype, "textContent", {
    get: function () {
      return this.childNodes.reduce(function (text, kid) {
        return text + kid.textContent;
      }, this.ownText);
    },
  });

  Element.prototype.setAttribute = function (name, value) {
    this.attributes[name] = String(value);
    if (name === "id") {
      this.id = String(value);
    }
  };

  Element.prototype.getAttribute = function (name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name)
      ? this.attributes[name]
      : null;
  };

  Element.prototype.removeAttribute = function (name) {
    delete this.attributes[name];
    if (name === "id") {
      this.id = "";
    }
  };

  Element.prototype.appendChild = function (child) {
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  };

  Element.prototype.removeChild = function (child) {
    var at = this.childNodes.indexOf(child);
    if (at >= 0) {
      this.childNodes.splice(at, 1);
      child.parentNode = null;
    }
    return child;
  };

  Element.prototype.closest = function (selector) {
    for (var node = this; node; node = node.parentNode) {
      if (matches(node, selector)) {
        return node;
      }
    }
    return null;
  };

  Element.prototype.getBoundingClientRect = function () {
    var laid = this.box || box(0, 0, 0, 0);
    var left = laid.x - win.scrollX;
    var top = laid.y - win.scrollY;
    return {
      x: left,
      y: top,
      left: left,
      top: top,
      width: laid.width,
      height: laid.height,
      right: left + laid.width,
      bottom: top + laid.height,
    };
  };

  // One simple selector: `[attribute]` or a tag name — enough for `closest` and the fixture.
  function matches(node, selector) {
    var one = selector.trim();
    if (one.charAt(0) === "[") {
      var name = one.slice(1, -1);
      if (name === "id") {
        return !!node.id;
      }
      return Object.prototype.hasOwnProperty.call(node.attributes, name);
    }
    return node.tagName === one;
  }

  function descendants(root, into) {
    var found = into || [];
    for (var i = 0; i < root.childNodes.length; i++) {
      found.push(root.childNodes[i]);
      descendants(root.childNodes[i], found);
    }
    return found;
  }

  var documentElement = new Element("html");
  documentElement.scrollWidth = 800;
  documentElement.scrollHeight = 2000;
  var body = new Element("body");
  documentElement.appendChild(body);

  var emptySelection = {
    isCollapsed: true,
    rangeCount: 0,
    toString: function () {
      return "";
    },
  };
  var selection = emptySelection;

  var listeners = { window: {}, document: {} };

  function listen(bag, type, fn) {
    bag[type] = bag[type] || [];
    bag[type].push(fn);
  }

  function fire(bag, type, event) {
    var fns = bag[type] || [];
    for (var i = 0; i < fns.length; i++) {
      fns[i](event);
    }
  }

  var doc = {
    body: body,
    documentElement: documentElement,
    // An array on the document, exactly as a browser has — the script re-checks membership on
    // every paint rather than trusting that what it adopted once is still adopted, so a stub
    // that made this a no-op would let that check pass vacuously.
    adoptedStyleSheets: [],
    addEventListener: function (type, fn) {
      listen(listeners.document, type, fn);
    },
    createElementNS: function (namespace, tag) {
      return new Element(tag);
    },
    querySelectorAll: function (selector) {
      var parts = selector.split(",");
      return descendants(documentElement).filter(function (node) {
        return parts.some(function (part) {
          return matches(node, part);
        });
      });
    },
    elementFromPoint: function (x, y) {
      var hit = null;
      descendants(documentElement).forEach(function (node) {
        if (!node.box) {
          return;
        }
        var r = node.getBoundingClientRect();
        // Document order, last match wins — a child is laid out after its parent, so this
        // is the topmost element the way a real hit test resolves it.
        if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
          hit = node;
        }
      });
      return hit;
    },
    getSelection: function () {
      return selection;
    },
  };

  // The element a browser would fire a mouse event AT.
  function pointerTarget(clientX, clientY) {
    return doc.elementFromPoint(clientX, clientY);
  }

  // The CSS Custom Highlight API, to the extent the script touches it — a document-wide
  // registry keyed by name, and a `Highlight` holding the ranges it was constructed with.
  //
  // **Modelled on what a real WKWebView answered, not on the spec.** The measurement that
  // decided this feature exists at all was taken from the bridge content world of a live
  // embed: `CSS.highlights` and `Highlight` are there, a highlight registered from the
  // isolated world is visible to the PAGE world — so the registry is the document's rather
  // than the world's, which is the only reason the renderer would ever paint it — and a
  // constructed stylesheet adopted from the isolated world parses its `::highlight()` rule.
  // `CanvasMarkReachesAgentLiveTests` keeps that measurement as a gate, because none of it is
  // reproducible here: this is a registry, not a renderer, and nothing in this file can say a
  // pixel changed colour.
  //
  // A `Highlight`'s ranges are exposed as `ranges` for the harness to read back. A browser's
  // is Set-like and iterated; the script only ever constructs one, so what a test needs is a
  // way to ask which range went in.
  var highlights = {};

  function Highlight(range) {
    this.ranges = [range];
  }

  function StyleSheet() {
    this.cssText = "";
  }

  StyleSheet.prototype.replaceSync = function (text) {
    this.cssText = String(text);
  };

  var posted = [];
  var win = {
    scrollX: 0,
    scrollY: 0,
    CSS: {
      highlights: {
        set: function (name, highlight) {
          highlights[name] = highlight;
        },
        get: function (name) {
          return Object.prototype.hasOwnProperty.call(highlights, name)
            ? highlights[name]
            : undefined;
        },
        has: function (name) {
          return Object.prototype.hasOwnProperty.call(highlights, name);
        },
        delete: function (name) {
          delete highlights[name];
        },
      },
    },
    Highlight: Highlight,
    CSSStyleSheet: StyleSheet,
    addEventListener: function (type, fn) {
      listen(listeners.window, type, fn);
    },
    webkit: {
      messageHandlers: {
        helmCanvas: {
          postMessage: function (message) {
            posted.push(message);
          },
        },
      },
    },
  };

  // The negative control: a canvas with no bridge (`playwright-cli` opening the artifact
  // directly) must be left completely alone.
  if (global.__helmNoBridge) {
    delete win.webkit;
  }

  function node(tag, id, text, laid) {
    var el = new Element(tag);
    if (id) {
      el.setAttribute("id", id);
    }
    el.ownText = text || "";
    el.box = laid || null;
    return el;
  }

  // The shape `CanvasHTML.documentPage` produces: everything inside `<article id="content">`.
  // `#content` is deliberately here: it is the helm-written ancestor a mark must not be named
  // by (#215).
  //
  // `body` is deliberately NOT laid out, so a point outside `#content` hits nothing at all.
  var content = node("article", "content", "", box(0, 0, 760, 1800));
  // helm's own chrome, marked the way `CanvasHTML.documentPage` marks it. The marker is the
  // ONLY thing that distinguishes this from an agent-authored `<div id="content">` at the top
  // of an `.html` artifact — see `asHTMLArtifact` below, which is that same page with the
  // marker taken off.
  content.setAttribute("data-helm-frame", "");
  body.appendChild(content);
  content.appendChild(node("h1", "title", "The Plan", box(20, 20, 700, 40)));
  content.appendChild(node("p", "intro", "Why this exists", box(20, 80, 700, 60)));
  content.appendChild(node("p", "detail", "How it works", box(20, 160, 700, 60)));
  content.appendChild(node("li", "item-a", "Item A", box(20, 1400, 300, 30)));
  content.appendChild(node("li", "item-b", "Item B", box(400, 1400, 300, 30)));

  // **Everything above this line carries an id, and that is how #215 survived.** When the
  // marked element has its own id the walk in `resolve` stops on its first iteration, so the
  // element it stops on IS the element that was marked and the right text comes back by
  // accident. The defect only exists for an element with NO id — of which the fixture had
  // none, including in the test named `testTheWholeDocumentIsNotQuotedBackAtTheAgent`.
  //
  // `marked` gives paragraphs no id, so an id-less block is what a markdown canvas is made
  // of. Two of them, laid out apart, because a second one is what proves the `(id, text)`
  // dedupe separates siblings that once produced the identical pair.
  //
  // Placed in the 1150-1330 band, which no existing test's stroke reaches: #208's fixtures
  // sit at the page centroid and at y≈700-1110, the loop tests at y≈1390-1440, and
  // `testALoopAroundNothingSelectsNothing` needs y≈1600-1660 to stay empty.
  var named = node("h2", "phase-2", "Phase ", box(20, 1150, 700, 40));
  content.appendChild(named);
  // An id-less element inside an id-bearing one that is NOT helm's frame — the shape that
  // proves the ancestor walk survives. mermaid's node labels are exactly this: the hit lands
  // on a `<text>`/`<p>` inside the `<g>` carrying the id, so a resolver that read only the
  // marked element's own id would anchor no diagram at all (#113).
  named.appendChild(node("span", "", "two", box(120, 1150, 60, 40)));
  content.appendChild(node("p", "", "First unnamed block", box(20, 1220, 700, 40)));
  content.appendChild(node("p", "", "Second unnamed block", box(20, 1290, 700, 40)));

  function find(id) {
    var hits = descendants(documentElement).filter(function (el) {
      return el.id === id;
    });
    return hits[0] || null;
  }

  // The only handle an id-less element has. `find` addresses the fixture by id, which is
  // exactly the address a markdown block does not have — and not having one is the whole of
  // #215.
  function findByOwnText(ownText) {
    var hits = descendants(documentElement).filter(function (el) {
      return el.ownText === ownText;
    });
    return hits[0] || null;
  }

  // `cloneRange` is modelled rather than aliased to the range itself, and that is the whole
  // point of it being here. A browser's `getRangeAt(0)` hands back a range the Selection still
  // owns; the clone is the operator's mark and outlives the selection going away when the
  // comment field takes the keyboard. A stub returning `this` would let a script that forgot to
  // clone pass — so the clone carries `cloned: true` and a test asserts on it.
  function selectWithin(anchor, text) {
    function range(cloned) {
      return {
        cloned: cloned,
        text: text,
        commonAncestorContainer: anchor,
        getBoundingClientRect: function () {
          return anchor.getBoundingClientRect();
        },
        cloneRange: function () {
          return range(true);
        },
      };
    }
    selection = {
      isCollapsed: false,
      rangeCount: 1,
      toString: function () {
        return text;
      },
      getRangeAt: function () {
        return range(false);
      },
    };
  }

  /// Drop the operator's highlight the way the comment field taking the keyboard does — the
  /// native selection goes, and helm's mark is supposed to stay.
  function collapseSelection() {
    selection = emptySelection;
  }

  global.window = win;
  global.document = doc;
  global.__helm = {
    posted: posted,
    // Both halves of what Swift pushes. The tint is not decoration: without it the script
    // paints nothing at all, deliberately (`CanvasHTML.setMarkTool` argues why there is no
    // fallback colour), so a harness that set only the tool would report every highlight
    // assertion as a failure of the feature rather than of the fixture.
    setTool: function (tool, tint) {
      win.__helmMarkTool = tool;
      win.__helmMarkTint = tint;
    },
    // Page coordinates in; the stub derives the viewport pair the way a browser does.
    mouse: function (type, pageX, pageY, button) {
      var prevented = false;
      fire(listeners.document, type, {
        button: button || 0,
        pageX: pageX,
        pageY: pageY,
        clientX: pageX - win.scrollX,
        clientY: pageY - win.scrollY,
        // The element a browser would report.
        target: pointerTarget(pageX - win.scrollX, pageY - win.scrollY),
        preventDefault: function () {
          prevented = true;
        },
      });
      return prevented;
    },
    // A mounted drawable board, the shape `@quickdrawjs/core` actually produces: one container
    // carrying `data-helm-surface`, a `<canvas>` inside it that every pointer event targets,
    // and chrome with readable text.
    //
    // **Created on demand, never in the default fixture.** Every other test in this suite
    // shares that fixture, and a laid-out element added to it silently changes what their
    // gestures hit. This one is opt-in, so #111's tests are the only ones that meet it.
    mountBoard: function () {
      var container = node("main", "board", "", box(20, 450, 700, 200));
      container.setAttribute("data-helm-surface", "");
      body.appendChild(container);
      // No id, exactly as quickdraw's own `document.createElement('canvas')` has none — so
      // `closest` has to walk to find the declaration rather than reading it off the target.
      container.appendChild(node("canvas", "", "", box(20, 450, 700, 200)));
      container.appendChild(node("p", "board-tools", "Select Draw Arrow Text", box(24, 454, 200, 24)));
      return true;
    },
    fireOnWindow: function (type) {
      fire(listeners.window, type, {});
    },
    fireOnDocument: function (type) {
      fire(listeners.document, type, {});
    },
    listenerCount: function (which, type) {
      var bag = which === "window" ? listeners.window : listeners.document;
      return (bag[type] || []).length;
    },
    // The same DOM, minus helm's frame marker — which is exactly what an `.html` ARTIFACT is,
    // since helm reads those from disk and generates nothing in them. The marker is the only
    // difference, which is the point; `CanvasAnchorTests` says why that matters.
    asHTMLArtifact: function () {
      content.removeAttribute("data-helm-frame");
    },
    select: function (id, text) {
      selectWithin(find(id), text);
    },
    selectInBlock: function (ownText, text) {
      selectWithin(findByOwnText(ownText), text);
    },
    collapseSelection: collapseSelection,
    highlightNames: function () {
      return Object.keys(highlights);
    },
    // What the named highlight covers: the id of the element the range sits in, the text it
    // was made over, and whether the script cloned the range before registering it.
    highlightedRange: function (name) {
      var held = highlights[name];
      if (!held) {
        return null;
      }
      var range = held.ranges[0];
      return {
        id: range.commonAncestorContainer ? range.commonAncestorContainer.id : "",
        text: range.text || "",
        cloned: !!range.cloned,
      };
    },
    // Every adopted sheet's text, joined — so a test can assert the `::highlight()` rule
    // exists AND carries the colour Swift pushed, rather than one or the other.
    adoptedStyle: function () {
      return doc.adoptedStyleSheets
        .map(function (sheet) {
          return sheet.cssText;
        })
        .join("\n");
    },
    adoptedSheetCount: function () {
      return doc.adoptedStyleSheets.length;
    },
    // A page replacing `document.adoptedStyleSheets` wholesale, which is a thing an artifact's
    // own script may do — the rule has to come back or the registered highlight paints nothing.
    dropAdoptedStyles: function () {
      doc.adoptedStyleSheets = [];
    },
  };
})(this);

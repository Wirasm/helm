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
//     exactly as the real thing behaves. That is what puts the script's `window.scrollX`
//     corrections under test instead of assuming them — #196 lived in that gap.
//   - The mark layer covers the whole document for hit-testing while it is displayed, because
//     `position:absolute` at `z-index: 2147483647` over `scrollWidth`×`scrollHeight` does.
//     That is the hazard `targetAt` hides it for, so the stub reproduces it rather than
//     letting the hide pass vacuously.
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

  // One simple selector: `[attribute]` or a tag name. That is the whole vocabulary the
  // script uses — `"[id], p, li, td, th, h1, h2, h3"` and `"[data-helm-mark]"`.
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

  function markLayer() {
    for (var i = 0; i < body.childNodes.length; i++) {
      if (body.childNodes[i].getAttribute("data-helm-mark") !== null) {
        return body.childNodes[i];
      }
    }
    return null;
  }

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
      var paper = markLayer();
      if (paper && paper.style.display !== "none") {
        return paper;
      }
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

  var posted = [];
  var win = {
    scrollX: 0,
    scrollY: 0,
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

  // The negative control: a canvas with no bridge (a URL canvas, or `playwright-cli` opening
  // the artifact directly) must be left completely alone.
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
  // `#content` is deliberately here — it is the ancestor #208 is about — but the fixture puts
  // the two list items far from its centroid so a loop round one of them is unambiguous, and
  // no test in this suite pins #208's behaviour either way.
  //
  // `body` is deliberately NOT laid out, so a point outside `#content` hits nothing at all:
  // that is "an arrow into blank space", which is a mark helm has to be able to make.
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

  function selectWithin(anchor, text) {
    selection = {
      isCollapsed: false,
      rangeCount: 1,
      toString: function () {
        return text;
      },
      getRangeAt: function () {
        return {
          commonAncestorContainer: anchor,
          getBoundingClientRect: function () {
            return anchor.getBoundingClientRect();
          },
        };
      },
    };
  }

  // Direct children of the paper only. The arrowhead's barb is a `<path>` too, nested inside
  // `<defs><marker>`, and counting it as ink made the first version of this harness report the
  // barb's `d` as the stroke the operator drew.
  function inMarkLayer(tag) {
    var paper = markLayer();
    if (!paper) {
      return [];
    }
    return paper.childNodes.filter(function (el) {
      return el.tagName === tag;
    });
  }

  global.window = win;
  global.document = doc;
  global.__helm = {
    posted: posted,
    setTool: function (tool) {
      win.__helmMarkTool = tool;
    },
    scrollTo: function (x, y) {
      win.scrollX = x;
      win.scrollY = y;
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
        preventDefault: function () {
          prevented = true;
        },
      });
      return prevented;
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
    hasMarkLayer: function () {
      return markLayer() !== null;
    },
    markLayerStyle: function () {
      var paper = markLayer();
      return paper ? paper.style.cssText : "";
    },
    inkPaths: function () {
      return inMarkLayer("path").map(function (el) {
        return { d: el.getAttribute("d"), markerEnd: el.getAttribute("marker-end") };
      });
    },
    ringCount: function () {
      return inMarkLayer("circle").length;
    },
    // `<marker id="helm-mark-head">` — helm's own chrome, and the only element in the mark
    // layer carrying an id, so the only one `targetsInside`'s query can pick up.
    markerIDs: function () {
      var paper = markLayer();
      if (!paper) {
        return [];
      }
      return descendants(paper)
        .filter(function (el) {
          return !!el.id;
        })
        .map(function (el) {
          return el.id;
        });
    },
    // Lay an element out, and give it text, after the fact.
    //
    // Both exist to make ONE assertion non-vacuous: that `closest("[data-helm-mark]")` keeps
    // helm's own chrome out of what a loop reports. Today's chrome — the arrowhead `<marker>`
    // — is already excluded twice over, once for having no size and once for having no text,
    // so removing the guard changes nothing and a test written against it as-shipped passes
    // either way (measured). A test has to construct the state the guard is actually for:
    // chrome that is laid out and readable, which is what any labelled mark would be.
    layOut: function (id, x, y, width, height) {
      var el = find(id);
      if (el) {
        el.box = box(x, y, width, height);
      }
      return el !== null;
    },
    giveText: function (id, text) {
      var el = find(id);
      if (el) {
        el.ownText = text;
      }
      return el !== null;
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
  };
})(this);

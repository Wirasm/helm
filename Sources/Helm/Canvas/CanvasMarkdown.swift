import Foundation

/// Source metadata lives on the DOM because rendering and selection run in separate worlds.
enum CanvasMarkdown {
    static let sourceAttribute = "data-helm-source"

    /// Only complete top-level Markdown blocks are stamped. Nested lists and blockquotes
    /// inherit their enclosing source, whose indentation and markers are still literal.
    static let renderScript = """
        var tokens = marked.lexer(source);
        var normalized = "", boundaries = [0];
        for (var i = 0; i < source.length; i++) {
          var character = source[i];
          if (character === "\\r") {
            if (source[i + 1] === "\\n") { i++; }
            character = "\\n";
          }
          normalized += character;
          boundaries.push(i + 1);
        }
        var excerpts = new Map(), cursor = 0;
        tokens.forEach(function (token) {
          var start = normalized.indexOf(token.raw, cursor);
          if (start < 0) { return; }
          cursor = start + token.raw.length;
          excerpts.set(token, source.slice(boundaries[start], boundaries[cursor]));
        });
        var renderer = new marked.Renderer();
        ["heading", "paragraph", "list", "blockquote", "table", "code"].forEach(function (method) {
          var render = renderer[method];
          renderer[method] = function (token) {
            var html = render.call(this, token);
            if (!excerpts.has(token)) { return html; }
            var fragment = document.createElement("template");
            fragment.innerHTML = html;
            var block = fragment.content.firstElementChild;
            if (block) { block.setAttribute("\(sourceAttribute)", JSON.stringify(excerpts.get(token))); }
            return fragment.innerHTML;
          };
        });
        content.innerHTML = marked.parser(tokens, { renderer: renderer });
        """
}

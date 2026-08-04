import Foundation

/// Reduces a mermaid-rendered element id to the identifier that appears in the
/// ```mermaid fence — so an annotation anchors to something the agent can grep.
///
/// mermaid builds a node's DOM id out of three parts the *renderer* chose and one
/// the *author* chose:
///
/// ```
/// mermaid-0-flowchart-phase2-1
/// └──┬──┘ └───┬────┘ └─┬──┘ └┬┘
///    │        │        │     └─ layout counter — moves when nodes are added or reordered
///    │        │        └─ THE ONLY PART THAT IS IN THE SOURCE
///    │        └─ diagram family
///    └─ per-page diagram index
/// ```
///
/// Only the third part survives an edit. Measured against the vendored bundle in a real
/// WKWebView (#113): with `deterministicIds: true` the whole id is stable across
/// *re-renders*, but four of five source edits — adding a node above, removing one,
/// reordering, or adding a second diagram to the page — still move the prefix or the
/// counter. Since `FileWatcher` re-renders precisely *because* the agent rewrote the
/// file, an anchor holding the full id is stale exactly when it is needed.
///
/// So helm hands over `phase2`, following the greppability principle: prefer an
/// identifier that actually exists in the source the agent will edit, over one that is
/// merely unique in the DOM.
///
/// **Only the families that put the author's identifier in the id can be reduced.**
/// `mindmap` emits `node_0` and `sequenceDiagram` emits `actor0` — a positional index
/// with the source name nowhere in the DOM, so there is nothing to recover and this
/// returns nil rather than inventing one.
enum MermaidAnchor {
    /// Diagram families whose node ids carry the source identifier, in the shape
    /// `mermaid-<diagram>-<family>-<identifier>-<counter>`. Verified by rendering each
    /// family in a WKWebView against the vendored build.
    private static let families = ["flowchart", "classId", "state", "entity"]

    /// Whether this id was minted by the renderer rather than written by the agent.
    ///
    /// The distinction matters because "cannot reduce" has two very different causes. An id
    /// the agent authored (`phase-2`, `overview`) is already the greppable thing and must
    /// pass through untouched. An id mermaid minted that carries no author identifier —
    /// `mermaid-0-node_1` from a mindmap, an edge, a marker def — is renderer bookkeeping:
    /// keeping it produces an anchor that survives a re-render and means nothing to an agent
    /// grepping the source, which is the anchor #113 exists to abolish. Those degrade to a
    /// quote instead.
    ///
    /// **A ceiling, stated rather than hidden:** `sequenceDiagram` emits `actor0` and
    /// `root-0` with no `mermaid-` prefix at all, so they are indistinguishable from an id an
    /// agent wrote by hand. helm cannot tell, and does not guess.
    static func isRenderGenerated(_ id: String) -> Bool {
        guard id.hasPrefix("mermaid-") else { return false }
        let rest = id.dropFirst("mermaid-".count)
        guard let end = rest.firstIndex(where: { !$0.isNumber }) else { return true }
        guard end != rest.startIndex else { return false }
        return rest[end] == "-" || rest[end] == "_"
    }

    /// The fence identifier inside a rendered mermaid node id, or nil if `renderedID`
    /// is not one — an edge, a marker def, the `<svg>` itself, a family that encodes no
    /// identifier, or an id the agent authored by hand. Nil means "leave it alone".
    ///
    /// Pure: no WebKit, no page, no I/O.
    static func sourceIdentifier(in renderedID: String) -> String? {
        guard renderedID.hasPrefix("mermaid-") else { return nil }
        var rest = renderedID.dropFirst("mermaid-".count)

        // <diagram index> — digits only, so `mermaid-0_flowchart-v2-pointEnd` (a marker
        // def, which uses `_` here rather than `-`) fails on the first segment.
        guard let indexEnd = rest.firstIndex(of: "-") else { return nil }
        let diagramIndex = rest[rest.startIndex..<indexEnd]
        guard !diagramIndex.isEmpty, diagramIndex.allSatisfy(\.isNumber) else { return nil }
        rest = rest[rest.index(after: indexEnd)...]

        // <family>
        guard let family = families.first(where: { rest.hasPrefix("\($0)-") }) else { return nil }
        rest = rest.dropFirst(family.count + 1)

        // <identifier>-<counter>, taking the LAST dash: an identifier may itself contain
        // dashes (`phase-2` is the shape helm's own docs use), and the counter may not.
        guard let counterStart = rest.lastIndex(of: "-") else { return nil }
        let counter = rest[rest.index(after: counterStart)...]
        guard !counter.isEmpty, counter.allSatisfy(\.isNumber) else { return nil }

        let identifier = rest[rest.startIndex..<counterStart]
        guard !identifier.isEmpty else { return nil }
        return String(identifier)
    }
}

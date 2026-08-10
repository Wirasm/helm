import Foundation

/// One thing the operator marked on a canvas, and what they said about it.
///
/// The anchor is a DOM element id where the page has one, because the ASYMMETRY that
/// decides this is that the agent AUTHORED the page (#33): it knows its own ids, so
/// `#phase-2` is directly editable rather than merely descriptive. It degrades to quoted
/// text for a `.md` canvas or any section without an authored id.
///
/// **The anchor carries no image**, and there is deliberately no field here that could
/// carry one: an anchor made of pixels is not something the agent can edit, which is the
/// same reason the anchor is an id rather than a rect.
///
/// That is a fact about this payload and nothing wider. #39 asks only for "no screenshots
/// in the payload", as one acceptance checkbox — helm has no rule against screenshots as
/// such, and could not: a canvas is *validated* by screenshotting the rendered page, which
/// is exactly why #39's own load-bearing constraint is that canvases stay self-contained
/// rather than render as "a blank page in playwright".
struct CanvasAnnotation: Equatable {
    enum Anchor: Equatable {
        case element(id: String, text: String)
        case quote(String)
    }

    /// What the operator drew, and what it names (#112).
    ///
    /// **Classify the gesture; do not digitise it.** No case carries a coordinate. SketchVLM
    /// ships no shape recogniser and tldraw sends no freehand geometry at all — what travels
    /// in every system that works is *type plus target*. A mark made of pixels is not
    /// something the agent can edit, which is the same reason an anchor is an id and not a
    /// rect.
    enum Mark: Equatable {
        /// Text the operator selected. helm's behaviour before this slice, unchanged.
        case selection(Anchor)
        /// A circle or box. **Multiplicity is data, not an error** — circling three nodes
        /// means all three, and flattening that to "the nearest one" would be helm deciding
        /// what the operator meant.
        case enclosure(covering: [Anchor])
        /// An arrow. Both ends are optional because an arrow into empty space is a real
        /// thing to draw — "add a node here" — so it is representable rather than refused.
        /// Both ends nil is the one shape that means nothing.
        case relation(from: Anchor?, to: Anchor?)
        /// A tap: the nearest thing under it.
        case point(Anchor)
    }

    var mark: Mark
    var comment: String

    /// **`private` is the gate's exclusivity, said by the compiler instead of by a comment**
    /// (#326). `decode` below promises *"every field is type-checked and bounded… never a crash,
    /// never a half-written note"*, and while the memberwise initializer was synthesized at
    /// `internal` that promise was prose: anything in the module could assemble a mark the gate
    /// would have refused. Fifteen fixtures across five test files already did.
    ///
    /// **That is `StandardizedPath`'s lesson two seams over** — a doc comment asking callers to
    /// prefer a helper, taken around by a test anyway (#88), fixed by making the unchecked value
    /// unconstructable rather than by asking again. `@testable import` raises `internal` and does
    /// **not** raise `private`, so a fixture cannot take the shortcut either.
    ///
    /// **`private`, chosen rather than inherited from #323, which used `fileprivate` for the
    /// sibling type one file over.** The two cases are not the same shape, and that is what
    /// decides it: `CanvasSelection`'s gate is `CanvasPageSelection.decode` — a **different
    /// type** — so `private` would have shut its own gate out and `fileprivate` was the tightest
    /// available. This gate is `CanvasAnnotation.decode`, a static member of *this* type in a
    /// same-file extension, and SE-0169 gives those access to `private` members. So the wider
    /// scope buys nothing here and costs a door: measured, a sibling declaration **in this very
    /// file** is refused under `private` and admitted under `fileprivate`.
    ///
    /// A nested type with a `private` init was the other candidate and is the same scope by a
    /// longer road — it is what you reach for when the gate lives on a different type and
    /// `fileprivate` is too wide. Here the plain member modifier already is that scope, so
    /// nesting would rename the type at every use site and buy nothing.
    ///
    /// This is now the **only** initializer. `init(anchor:comment:)` — *"a selection is the
    /// ordinary construction, and was the only one before #112"* — went with the bypasses it
    /// existed for: `decode` never called it, so once the fixtures went through the gate it had
    /// no caller left in either target, and a private initializer nothing calls is not a second
    /// door but litter behind the first.
    private init(mark: Mark, comment: String) {
        self.mark = mark
        self.comment = comment
    }
}

extension CanvasAnnotation {
    /// An enclosure may not cover an unbounded number of things — a drag across a whole
    /// document is not a mark, it is a mistake.
    static let maximumEnclosureCount = 32

    /// An element id is at most this long, and holds only characters that can appear in
    /// one. Anything else is a page trying to write something other than an id.
    static let maximumIDLength = 200
    /// Selected text beyond this is not a selection, it is a document.
    static let maximumTextLength = 2000

    private static let allowedIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_:.-")

    /// From the bridge's message body.
    ///
    /// The page is agent-authored, not helm-authored, so this treats the body as
    /// untrusted: every field is type-checked and bounded, and a malformed body is nil —
    /// never a crash, never a half-written note. The shape mirrors
    /// `CanvasURLPolicy.address(_:)`: a hostile value in, a validated one or nothing out,
    /// because a note that resolves to nothing is better refused than guessed at.
    ///
    /// `WKScriptMessage.body` is `Any` bridged from JS — `NSDictionary`/`NSString`/
    /// `NSNumber`, and a JS number arrives as `NSNumber` rather than `Int`. Type-check,
    /// never force-cast.
    static func decode(_ body: Any, comment: String) -> CanvasAnnotation? {
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { return nil }
        guard let payload = body as? [String: Any] else { return nil }

        switch CanvasPageSelection.Kind(rawValue: payload["kind"] as? String ?? "") {
        case .enclosure:
            let covered = decodedAnchors(payload["targets"])
            // Refused rather than shipped as a coordinate: a circle around nothing is the
            // operator pointing at empty space, and helm has no honest anchor for that.
            guard !covered.isEmpty, covered.count <= maximumEnclosureCount else { return nil }
            return CanvasAnnotation(mark: .enclosure(covering: covered), comment: comment)

        case .relation:
            let from = decodedAnchor(payload["from"])
            let to = decodedAnchor(payload["to"])
            // One end may be empty — that is "add a node here". Neither end is nothing.
            guard from != nil || to != nil else { return nil }
            return CanvasAnnotation(mark: .relation(from: from, to: to), comment: comment)

        case .point:
            guard let at = decodedAnchor(payload) else { return nil }
            return CanvasAnnotation(mark: .point(at), comment: comment)

        case .selection:
            guard let at = decodedAnchor(payload) else { return nil }
            return CanvasAnnotation(mark: .selection(at), comment: comment)

        case .cleared, .none:
            // **A kind this build does not know is refused, and that reverses what this
            // `default` used to do** (#109). It used to fall through to a text selection, on
            // the reasoning that *"the page is agent-authored and a future mark helm has not
            // learned is not a reason to throw away a comment"* — but the page posting here is
            // not agent-authored: the bridge lives in a named content world (#164), so the only
            // thing that can post is `canvas-annotation.js`, which ships in the same binary as
            // this switch. An unknown kind is therefore not a newer page, it is drift — and
            // guessing "it was probably a selection" is how a lasso would silently become a
            // highlight over whatever text happened to be in the payload.
            //
            // `.cleared` lands here too, and always did: a dismissal is not a note.
            return nil
        }
    }

    /// One target — an element with an id, or the text it covers.
    ///
    /// **The one place a DOM id becomes an anchor**, so the draw-time hit test and any later
    /// re-resolution cannot disagree about what a mark named (#112's own acceptance).
    private static func decodedAnchor(_ raw: Any?) -> Anchor? {
        guard let payload = raw as? [String: Any] else { return nil }
        guard let text = sanitizedText(payload["text"]) else { return nil }
        guard let id = payload["id"] as? String, let valid = validID(id) else {
            return .quote(text)
        }
        if let identifier = MermaidAnchor.sourceIdentifier(in: valid) {
            // The fence identifier — greppable in the file the agent will edit (#113).
            return .element(id: identifier, text: text)
        }
        if MermaidAnchor.isRenderGenerated(valid) {
            // A rendered id carrying no author identifier: a mindmap's `node_1`, an edge, a
            // marker def. Keeping it would hand the agent an anchor that survives a
            // re-render and matches nothing in the source — precisely the anchor #113
            // abolished, reintroduced by the back door. Degrade to the quote instead.
            return .quote(text)
        }
        // An id the agent authored. Already the greppable thing.
        return .element(id: valid, text: text)
    }

    private static func decodedAnchors(_ raw: Any?) -> [Anchor] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap(decodedAnchor)
    }

    private static func validID(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= maximumIDLength,
            id.unicodeScalars.allSatisfy(allowedIDCharacters.contains)
        else { return nil }
        return id
    }

    /// Control characters out — a selection that carries them is not text the operator
    /// pointed at — and length bounded. Refused rather than truncated: half a quotation
    /// anchors to the wrong place just as confidently as a whole one.
    private static func sanitizedText(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let stripped = String(
            String.UnicodeScalarView(
                raw.unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
                }))
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumTextLength else { return nil }
        return trimmed
    }
}

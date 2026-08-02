import Foundation

/// One thing the operator marked on a canvas, and what they said about it.
///
/// The anchor is a DOM element id where the page has one, because the ASYMMETRY that
/// decides this is that the agent AUTHORED the page (#33): it knows its own ids, so
/// `#phase-2` is directly editable rather than merely descriptive. It degrades to quoted
/// text for a `.md` canvas or any section without an authored id.
///
/// **No screenshot, ever** — #39 forbids it, and there is deliberately no field here that
/// could carry one.
struct CanvasAnnotation: Equatable {
    enum Anchor: Equatable {
        case element(id: String, text: String)
        case quote(String)
    }
    var anchor: Anchor
    var comment: String
}

extension CanvasAnnotation {
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
        guard let text = sanitizedText(payload["text"]) else { return nil }

        if let id = payload["id"] as? String, let valid = validID(id) {
            return CanvasAnnotation(anchor: .element(id: valid, text: text), comment: comment)
        }
        // The documented degradation, not a failure: markdown goes through `marked`
        // client-side and headings get no id unless the page adds one, so `.md` canvases
        // mostly produce quotes. Teaching agents to emit ids on sections is the other
        // half, and it lives in prp rather than in helm.
        return CanvasAnnotation(anchor: .quote(text), comment: comment)
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

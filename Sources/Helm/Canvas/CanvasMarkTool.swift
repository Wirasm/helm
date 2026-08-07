import Foundation

/// What the operator is holding when they touch the canvas (#112).
///
/// **The tool declares the type, so nothing has to guess it.** The first cut of this slice
/// inferred the mark from the gesture's shape — a drag that started on one node and ended on
/// another was an arrow, anything else was a circle. That is a heuristic sitting exactly
/// where the research says ambiguity bites: CHI '26 measured that *"similar sketches could
/// point to different intentions"*, on systems that send pixels. Picking up the arrow removes
/// the question rather than answering it better, and it makes the page simpler, not harder.
///
/// **Freehand is input, not payload.** Drawing a loop is how a person circles something; what
/// travels to the agent is still `Mark` — type plus target, no coordinate. That is what
/// tldraw does: it withholds the polyline entirely. The stroke is discarded once it has
/// resolved to what it covers. So "classify the gesture, do not digitise it" constrains what
/// helm *sends*, and never constrained what the operator's hand is allowed to do — the two
/// were conflated in the first attempt.
///
/// **Reading is a tool, because the alternative is a surface that can never be inert** (#302).
/// There was one case here called `select`, and its own doc comment admitted it carried two
/// jobs: *"Read the page. Text selection, exactly as before this slice existed."* That is both
/// "I am looking at this, do not interpret my mouse" and "what I select is the subject of a
/// comment", and the difference between them is not observable from a gesture — a
/// double-click that lands on a word while reading is byte-identical to one that means it.
/// The other three are unambiguous for one reason and it is not their shape: **the operator
/// picks them up**. Text marking was the only one always armed, so every click on every canvas
/// was a candidate mark, and the comment field opened on gestures nobody aimed.
///
/// So `.read` is a real case and it is the default. `.text` is the same job the other three do,
/// picked up the same way. What that buys beyond the popup: a canvas can now be **inert**, and
/// that is the precondition for editing one (#289) — while selecting text means marking, every
/// click made while editing is a mark.
enum CanvasMarkTool: String, CaseIterable, Equatable {
    /// Read the page, and helm interprets nothing at all. Text selects natively, exactly as on
    /// any web page — but nothing is posted, no comment field appears, and no dismissal is
    /// sent either. The default, and the only tool that is silent rather than quiet.
    case read
    /// Mark text: what you select is the subject of a comment. Picked up, like the three below.
    case text
    /// Draw a loop around things.
    case freehand
    /// Drag from one thing to another.
    case arrow
    /// Tap the thing.
    case point

    /// The token the page reads. `rawValue` deliberately — one spelling, so the picker and
    /// the script cannot drift apart, and a test can assert the set matches.
    var token: String { rawValue }

    /// SF Symbol for the picker.
    var symbol: String {
        switch self {
        case .read: "cursorarrow"
        case .text: "text.cursor"
        case .freehand: "pencil.and.outline"
        case .arrow: "arrow.up.right"
        case .point: "hand.point.up.left"
        }
    }

    /// What the operator is told it does. Phrased as the gesture, because that is what they
    /// are about to perform — except `.read`, which is phrased as the absence of one, because
    /// that is the whole of what it offers.
    var help: String {
        switch self {
        case .read: "Read the page — helm marks nothing"
        case .text: "Select text to comment on it"
        case .freehand: "Circle things by drawing round them"
        case .arrow: "Draw an arrow from one thing to another"
        case .point: "Point at one thing"
        }
    }

    /// Whether the **page** takes the pointer over from the browser for this tool — the
    /// `preventDefault` in `canvas-annotation.js`'s `mousedown`, and with it the stroke and
    /// the ink.
    ///
    /// **Not "does this tool mark".** `.text` marks and is `false` here, because a text mark
    /// *is* the browser's own selection and cancelling `mousedown` is precisely what would
    /// stop the operator making one. The two questions were the same one while `.select`
    /// existed and are not the same one now, so this answers only the pointer.
    ///
    /// **Exhaustive on purpose.** It was `self != .select`, which silently made any case
    /// added later a drawing tool — the verdict a sixth tool most needs to state is the one
    /// it would never have been asked for. `CanvasMarkToolTests
    /// .testThePageTakesThePointerForExactlyTheToolsThatDraw` is what holds this to the
    /// script's own two literals, over `allCases`, since a JavaScript file cannot compile
    /// against a Swift enum.
    var draws: Bool {
        switch self {
        case .read, .text: false
        case .freehand, .arrow, .point: true
        }
    }
}

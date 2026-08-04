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
enum CanvasMarkTool: String, CaseIterable, Equatable {
    /// Read the page. Text selection, exactly as before this slice existed.
    case select
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
        case .select: "cursorarrow"
        case .freehand: "pencil.and.outline"
        case .arrow: "arrow.up.right"
        case .point: "hand.point.up.left"
        }
    }

    /// What the operator is told it does. Phrased as the gesture, because that is what they
    /// are about to perform.
    var help: String {
        switch self {
        case .select: "Select text"
        case .freehand: "Circle things by drawing round them"
        case .arrow: "Draw an arrow from one thing to another"
        case .point: "Point at one thing"
        }
    }

    /// Whether this tool draws rather than reads — the page only takes over the pointer for
    /// these, so a canvas with `.select` held behaves exactly as it always has.
    var draws: Bool { self != .select }
}

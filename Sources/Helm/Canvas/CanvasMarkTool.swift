import Foundation

/// What the operator is holding when they touch the canvas (#112).
///
/// **Reading is a tool, because the alternative is a surface that can never be inert** (#302).
/// There was one case here called `select`, and it carried two jobs: *"Read the page"* and
/// *"what I select is the subject of a comment"*. The difference between them is not observable
/// from a gesture — a double-click that lands on a word while reading is byte-identical to one
/// that means it — so every click on every canvas was a candidate mark, and the comment field
/// opened on gestures nobody aimed. So `.read` is a real case and it is the default, and
/// marking text is a tool the operator picks up. What that buys beyond the popup: a canvas can
/// be **inert**, which is the precondition for editing one (#289).
///
/// **Two tools, and there were five.** Freehand, arrow and point were built for #112 and
/// removed in #385: five document marks were ever made, and the operator draws on the board
/// (helm-board) instead.
enum CanvasMarkTool: String, CaseIterable, Equatable {
    /// Read the page, and helm interprets nothing at all. Text selects natively, exactly as on
    /// any web page — but nothing is posted, no comment field appears, and no dismissal is
    /// sent either. The default, and the only tool that is silent rather than quiet.
    case read
    /// Mark text: what you select is the subject of a comment.
    case text

    /// The token the page reads. `rawValue` deliberately — one spelling, so the picker and
    /// the script cannot drift apart, and a test can assert the set matches.
    var token: String { rawValue }

    /// SF Symbol for the picker.
    var symbol: String {
        switch self {
        case .read: "cursorarrow"
        case .text: "text.cursor"
        }
    }

    /// What the operator is told it does. Phrased as the gesture, because that is what they
    /// are about to perform — except `.read`, which is phrased as the absence of one, because
    /// that is the whole of what it offers.
    var help: String {
        switch self {
        case .read: "Read the page — helm marks nothing"
        case .text: "Select text to comment on it"
        }
    }
}

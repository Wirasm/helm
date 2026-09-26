import Foundation
import HelmWire

/// The one door every change to the bench goes through (M4 PR 3b of #354).
///
/// A key, a click, a drag, a ⌘-clicked link, a `push.sh` and a spool command all describe what
/// they want as a `BenchVerb` and say who is asking. What carries it out is behind this protocol:
/// `LocalSink` today, and in PR 3c a sink that sends the same verb to benchd, which owns the
/// document from then on. Nothing that sends a verb has to change when that happens.
@MainActor
protocol VerbSink: AnyObject {
    /// Carry out `verb` as `by`. `asked` is the caller saying the operator asked for it, which
    /// lets an agent's verb take the keyboard the way the operator's own gesture does.
    ///
    /// Returns the pane the verb created or brought forward, when it did one of those; nil when
    /// it did neither, or could not act.
    @discardableResult
    func send(_ verb: BenchVerb, by: BenchActor, asked: Bool) -> Pane.ID?
}

extension VerbSink {
    @discardableResult
    func send(_ verb: BenchVerb, by: BenchActor) -> Pane.ID? {
        send(verb, by: by, asked: false)
    }
}

/// The workspace verbs the local sink hands on, as their own closed type: opening, closing and
/// switching workspaces span the workspace list and the bench together, so `RootView` carries
/// them out (`WorkbenchModel.workspaceVerbs`). A type rather than `BenchVerb` so the receiver's
/// `switch` is exhaustive and a verb added here cannot be silently dropped there.
enum WorkspaceVerb: Equatable {
    case open(String)
    case activate(String)
    case close(String)
}

extension Workbench.Direction {
    init(_ direction: BenchDirection) {
        switch direction {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        }
    }
}

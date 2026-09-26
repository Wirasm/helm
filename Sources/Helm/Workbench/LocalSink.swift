import Foundation
import HelmWire

/// What it takes to change the local bench directly: `WorkbenchModel`'s mutation methods each
/// ask for one, and only `LocalSink` can make one.
///
/// **The door, as a type.** Every change to the bench is a verb through `WorkbenchModel.send`,
/// and a caller reaching a mutation method directly would skip the sink — and, with benchd's
/// sink in, change a bench nobody renders from. The initializer is `fileprivate` to this file,
/// so a direct call anywhere else does not compile. (It was `fileprivate` methods with the sink
/// in the model's own file; that file outgrew its size limit, #433.)
struct LocalBenchKey {
    fileprivate init() {}
}

/// Applies a verb to `WorkbenchModel`'s own bench, with the methods helm has always used.
///
/// **This is today's behaviour, reached through the verb.** The one decision made here is
/// focus, and it is benchd's rule (`bench-doc`'s `Focus`): the keyboard moves only when the
/// operator acted, or when the caller says he asked. That picks between each pair of methods
/// helm already had — `open`/`offer`, `newTerminal`/`spawnTerminal`, `splitRight`/
/// `offerSplitRight`, `select`/`offerSelect` — which were the same two answers written twice.
///
/// PR 4 deletes this type with the local path, once benchd's sink has carried the operator's
/// own use.
@MainActor
final class LocalSink: VerbSink {
    private unowned let workbench: WorkbenchModel
    private let key = LocalBenchKey()

    init(workbench: WorkbenchModel) {
        self.workbench = workbench
    }

    /// Exhaustive over `BenchVerb`, one line per group, so a new verb is a compile error here
    /// until it has a local meaning.
    @discardableResult
    func send(_ verb: BenchVerb, by actor: BenchActor, asked: Bool) -> Pane.ID? {
        let takesFocus = actor == .operatorGesture || asked
        switch verb {
        case .paneOpen, .paneSplit, .paneShow:
            return make(verb, takesFocus: takesFocus)
        case .paneClose, .paneMove, .paneName, .paneRecord, .focusSlot, .focusStep, .layoutResize:
            arrange(verb)
            return nil
        case let .workspaceOpen(path):
            workbench.workspaceVerbs?(.open(path))
            return nil
        case let .workspaceActivate(path):
            workbench.workspaceVerbs?(.activate(path))
            return nil
        case let .workspaceClose(path):
            workbench.workspaceVerbs?(.close(path))
            return nil
        case .paneOpenInDrawer, .drawerToggle:
            // Drawers live in benchd's document; the local bench has none (#356).
            return nil
        case .get, .workspaceImport, .workspaceReset, .workspaceUnshelve:
            // Verbs that only mean something to benchd. Locally the bench is already here, and
            // #85's restore answer is the model's own `answer`, which shelves in helm's defaults.
            return nil
        }
    }

    /// The verbs that make or show a pane, and so answer with one.
    private func make(_ verb: BenchVerb, takesFocus: Bool) -> Pane.ID? {
        switch verb {
        case let .paneOpen(workspace, surface):
            return open(surface, in: workspace, takesFocus: takesFocus)
        case let .paneSplit(workspace, direction, surface):
            // A split holds a terminal; helm has no split for any other kind yet.
            guard isMounted(workspace), surface == nil || isTerminal(surface) else { return nil }
            let session =
                switch (direction, takesFocus) {
                case (.right, true): workbench.splitRight(key)
                case (.right, false): workbench.offerSplitRight(key)
                case (.down, true): workbench.splitDown(key)
                case (.down, false): workbench.offerSplitDown(key)
                }
            return session?.id
        case let .paneShow(pane):
            guard workbench.bench?.pane(pane) != nil else { return nil }
            if takesFocus { workbench.select(key, pane) } else { workbench.offerSelect(key, pane) }
            return pane
        default:
            preconditionFailure("\(verb.name) is not a verb that makes a pane; see send")
        }
    }

    /// The verbs that rearrange what is there.
    private func arrange(_ verb: BenchVerb) {
        switch verb {
        case let .paneClose(pane):
            workbench.close(key, pane)
        case let .paneMove(pane, direction):
            workbench.move(key, pane, Workbench.Direction(direction))
        case let .paneName(pane, name):
            workbench.name(key, pane, to: name)
        case let .paneRecord(pane, agent):
            workbench.record(key, agent.map(ResumableAgent.init), in: pane)
        case let .focusSlot(slot):
            workbench.focus(key, slot)
        case let .focusStep(workspace, direction):
            guard isMounted(workspace) else { return }
            workbench.moveFocus(key, Workbench.Direction(direction))
        case let .layoutResize(.columns(member, against), fraction):
            workbench.resizeColumn(key, member, to: fraction, against: against)
        case let .layoutResize(.slots(member, against), fraction):
            workbench.resizeSlot(key, member, to: fraction, against: against)
        default:
            preconditionFailure("\(verb.name) does not rearrange the bench; see send")
        }
    }

    private func open(_ surface: Surface, in workspace: String?, takesFocus: Bool) -> Pane.ID? {
        switch surface {
        case .terminal:
            guard isMounted(workspace) else { return nil }
            let session = takesFocus ? workbench.newTerminal(key) : workbench.spawnTerminal(key)
            return session?.id
        case let .canvas(path):
            let source = CanvasSource.file(URL(fileURLWithPath: path))
            // Only an agent's canvas can land on a parked bench: a push comes from terminal
            // output, which a workspace keeps producing after the operator leaves it (#349).
            if takesFocus {
                guard isMounted(workspace) else { return nil }
                return workbench.open(key, source)
            }
            let target = workspace.map(WorkspacePath.init) ?? workbench.workspacePath
            guard let target else { return nil }
            return workbench.offer(key, source, onBenchOf: target)
        case .browser:
            // Offered whoever asks (#350): the browser is something to glance at while work
            // goes on, and even the operator's ⌘⇧B leaves the keyboard where it was.
            guard isMounted(workspace) else { return nil }
            return workbench.offerBrowser(key)
        case .unsupported:
            return nil
        }
    }

    /// A verb that names a workspace acts only on the mounted one; nil means "the active one".
    private func isMounted(_ workspace: String?) -> Bool {
        workspace.map { WorkspacePath($0) == workbench.workspacePath } ?? true
    }

    private func isTerminal(_ surface: Surface?) -> Bool {
        if case .terminal = surface { true } else { false }
    }
}

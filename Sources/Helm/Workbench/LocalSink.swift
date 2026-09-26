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

    init(workbench: WorkbenchModel) {
        self.workbench = workbench
    }

    @discardableResult
    func send(_ verb: BenchVerb, by actor: BenchActor, asked: Bool) -> Pane.ID? {
        let takesFocus = actor == .operatorGesture || asked
        switch verb {
        case let .paneOpen(workspace, nil, surface):
            return open(surface, in: workspace, takesFocus: takesFocus)
        case .paneOpen(_, .some, _), .drawerToggle:
            // Drawers live in benchd's document; the local bench has none (#356).
            return nil
        case let .paneSplit(workspace, direction, surface):
            // A split holds a terminal; helm has no split for any other kind yet.
            guard isMounted(workspace), surface == nil || isTerminal(surface) else { return nil }
            let session =
                switch (direction, takesFocus) {
                case (.right, true): workbench.splitRight()
                case (.right, false): workbench.offerSplitRight()
                case (.down, true): workbench.splitDown()
                case (.down, false): workbench.offerSplitDown()
                }
            return session?.id
        case let .paneClose(pane):
            workbench.close(pane)
            return nil
        case let .paneShow(pane):
            guard workbench.bench?.pane(pane) != nil else { return nil }
            if takesFocus { workbench.select(pane) } else { workbench.offerSelect(pane) }
            return pane
        case let .paneMove(pane, direction):
            workbench.move(pane, Workbench.Direction(direction))
            return nil
        case let .paneName(pane, name):
            workbench.name(pane, to: name)
            return nil
        case let .focusSlot(slot):
            workbench.focus(slot)
            return nil
        case let .focusStep(workspace, direction):
            guard isMounted(workspace) else { return nil }
            workbench.moveFocus(Workbench.Direction(direction))
            return nil
        case let .layoutResize(divider, fraction):
            switch divider {
            case let .columns(member, against):
                workbench.resizeColumn(member, to: fraction, against: against)
            case let .slots(member, against):
                workbench.resizeSlot(member, to: fraction, against: against)
            }
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
        case .get, .workspaceImport, .workspaceReset, .workspaceUnshelve, .paneRecord:
            // Verbs that only mean something to benchd. Locally the bench is already here,
            // #85's restore answer is a direct call on the model, and which agent is in a pane
            // is `AgentObserver`'s — all three move onto verbs with PR 3c.
            return nil
        }
    }

    private func open(_ surface: Surface, in workspace: String?, takesFocus: Bool) -> Pane.ID? {
        switch surface {
        case .terminal:
            guard isMounted(workspace) else { return nil }
            let session = takesFocus ? workbench.newTerminal() : workbench.spawnTerminal()
            return session?.id
        case let .canvas(path):
            let source = CanvasSource.file(URL(fileURLWithPath: path))
            // Only an agent's canvas can land on a parked bench: a push comes from terminal
            // output, which a workspace keeps producing after the operator leaves it (#349).
            if takesFocus {
                guard isMounted(workspace) else { return nil }
                return workbench.open(source)
            }
            let target = workspace.map(WorkspacePath.init) ?? workbench.workspacePath
            guard let target else { return nil }
            return workbench.offer(source, onBenchOf: target)
        case .browser:
            // Offered whoever asks (#350): the browser is something to glance at while work
            // goes on, and even the operator's ⌘⇧B leaves the keyboard where it was.
            guard isMounted(workspace) else { return nil }
            return workbench.offerBrowser()
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

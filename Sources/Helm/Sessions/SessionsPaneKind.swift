import Foundation
import HelmWire
import SwiftUI

/// The sessions list as a `SurfaceKind` (#384): a `SessionsModel` per pane, drawn by
/// `SessionsView`. It lives in the `sessions` drawer (⌘⇧S), but a pane is a pane: an agent may
/// put one anywhere a surface can go.
@MainActor
final class SessionsPaneKind: SurfaceKind {
    /// Weak: the terminal manager is shared by every window, so the registration a closed
    /// window made can outlive its bench model. Once the model is gone this makes nothing.
    private weak var workbench: WorkbenchModel?
    private weak var terminals: TerminalManager?

    init(workbench: WorkbenchModel, terminals: TerminalManager) {
        self.workbench = workbench
        self.terminals = terminals
    }

    let kind: Pane.Content.Kind = .sessions

    func make(for pane: Pane, in workspace: WorkspacePath?) -> SessionsModel? {
        guard let workbench, let terminals else { return nil }
        return SessionsModel(actions: .live(workbench: workbench, terminals: terminals))
    }

    func view(of model: SessionsModel, in slot: SurfaceSlot) -> AnyView {
        AnyView(SessionsView(model: model, holdsKeyboard: slot.holdsKeyboard))
    }

    func tab(of model: SessionsModel, in slot: SurfaceSlot) -> AnyView {
        AnyView(
            PaneTab(
                title: slot.pane.name.text ?? "sessions", truncation: .tail,
                closeHelp: "Close the sessions list", slot: slot
            ) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 10))
            })
    }

    func close(_ model: SessionsModel) {}
}

extension SessionsActions {
    /// benchd at this helm's bench root, and the bench `workbench` draws.
    @MainActor
    static func live(
        workbench: WorkbenchModel, terminals: TerminalManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SessionsActions {
        let socket = BenchRoot.resolve(environment: environment)
            .map { $0.appendingPathComponent("benchd.sock").path }
            .mapError { Refused($0.sentence) }
        return SessionsActions(
            list: { workspace in
                let answer = try BenchClient.request(
                    BenchSessionsRequest.all(id: requestID(), workspace: workspace),
                    at: socket.get(), answering: BenchSessionList.self)
                guard answer.status == .ok, let list = answer.data else {
                    throw Refused(answer.reason ?? "benchd \(answer.status.rawValue)")
                }
                return list
            },
            dismiss: { harness, id in
                let answer = try BenchClient.request(
                    BenchSessionsRequest.dismiss(id: requestID(), harness: harness, session: id),
                    at: socket.get(), answering: EmptyAnswer.self)
                guard answer.status == .ok else {
                    throw Refused(answer.reason ?? "benchd \(answer.status.rawValue)")
                }
            },
            workspace: { [weak workbench] in workbench?.workspacePath },
            send: { [weak workbench] verb in workbench?.send(verb, by: .operatorGesture) },
            hideDrawer: { [weak workbench] in
                guard let workbench, let open = workbench.openDrawer else { return }
                workbench.send(.drawerToggle(name: open.name), by: .operatorGesture)
            },
            runInNewTerminal: { [weak workbench, weak terminals] line in
                guard let workbench, let terminals else { return "helm is closing" }
                return await NewTerminalLine.run(line, workbench: workbench, terminals: terminals)
            })
    }

    private static func requestID() -> String {
        "helm-\(UUID().uuidString.lowercased())"
    }

    /// benchd's refusal, as the list shows it.
    struct Refused: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// An answer whose data helm does not read.
    private struct EmptyAnswer: Decodable, Sendable {}
}

/// A new terminal on the bench, running one line once its shell is up.
///
/// **Waited on, never slept for**, the spool's rule: a line pasted before the login shell has
/// started is lost, and the shell having a foreground process is the pty's own answer to "am I
/// ready". The wait's direction is safe — a slow machine only makes it take longer.
@MainActor
enum NewTerminalLine {
    static func run(
        _ line: String, workbench: WorkbenchModel, terminals: TerminalManager,
        within deadline: Duration = .seconds(10)
    ) async -> String? {
        guard
            let pane = workbench.send(
                .paneOpen(surface: .terminal(agent: nil)), by: .operatorGesture)
        else { return "benchd did not open a terminal, so nothing was run" }
        let until = ContinuousClock.now + deadline
        while ContinuousClock.now < until {
            if let session = terminals.sessions.first(where: { $0.id == pane }),
                session.hostView.foregroundPid != nil
            {
                TerminalLaunchLine.send(line, to: session)
                return nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return "the new terminal's shell did not start within \(deadline), so nothing was run"
    }
}

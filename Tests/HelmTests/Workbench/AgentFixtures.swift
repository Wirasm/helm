import Foundation

@testable import Helm

/// The seam #63 put on `WorkbenchModel`, wired for tests.
///
/// **Nothing here reads the operator's own `~/.claude`.** `AgentObserver.live()` is the app's
/// wiring; a test that used it would be measuring the machine it runs on. Every rule is
/// exercised against pids and rows the test chose.
extension AgentObserver {
    /// An observer that sees no agents anywhere: the default for any test whose subject is not
    /// #63, so drawing a bench is deterministic without asserting anything about agents.
    @MainActor
    static var blind: AgentObserver {
        AgentObserver(sessionsNow: { [:] }, foregroundPid: { _ in nil })
    }

    /// An observer over a fixed registry.
    ///
    /// - Parameters:
    ///   - foreground: which pid has each terminal pane's terminal, by pane id.
    ///   - rows: the registry, by pid.
    @MainActor
    static func fixture(foreground: [UUID: pid_t], rows: [pid_t: AgentSession]) -> AgentObserver {
        AgentObserver(sessionsNow: { rows }, foregroundPid: { foreground[$0.id] })
    }
}

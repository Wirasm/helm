import Foundation

@testable import Helm

/// The two seams #63 put on `WorkbenchModel`, wired for tests.
///
/// **Nothing here reads the operator's own `~/.claude`.** `AgentObserver.live()` is the app's
/// wiring; a test that used it would be measuring the machine it runs on, and would light or
/// fail to light a resume offer depending on which agents happened to be running. Every rule is
/// exercised against pids and rows the test chose.
extension AgentObserver {
    /// An observer that sees no agents anywhere and finds every transcript present.
    ///
    /// The default for any test whose subject is not #63: it makes `activate` and `mount`
    /// deterministic without asserting anything about them.
    @MainActor
    static var blind: AgentObserver {
        AgentObserver(
            sessionsNow: { [:] }, foregroundPid: { _ in nil },
            transcriptExists: { _ in
                true
            })
    }

    /// An observer over a fixed registry.
    ///
    /// - Parameters:
    ///   - foreground: which pid each terminal session is running, by session id.
    ///   - rows: the registry, by pid.
    ///   - transcripts: session ids whose transcript is still on disk. `nil` means every one.
    @MainActor
    static func fixture(
        foreground: [UUID: pid_t],
        rows: [pid_t: AgentSession],
        transcripts: Set<String>? = nil
    ) -> AgentObserver {
        AgentObserver(
            sessionsNow: { rows },
            foregroundPid: { foreground[$0.id] },
            transcriptExists: { transcripts?.contains($0.session) ?? true })
    }
}

/// A launcher that records rather than writing to a pty.
///
/// The seam exists so `WorkbenchModel.resume` is reachable from `swift test` at all — the real
/// one needs a ghostty surface — and recording the line is what lets a test assert on the
/// composed command instead of on the fact that something was called.
@MainActor
final class RecordingLauncher: TerminalLaunching {
    private(set) var sent: [(line: String, terminal: Pane.ID)] = []

    func run(_ line: String, in terminal: Pane.ID) {
        sent.append((line, terminal))
    }
}

import Foundation

/// What a key does in the Archon drawer (#382), as a value: the view reads a key press, asks
/// this, and carries the answer out. Kept apart from SwiftUI so every key's meaning for every
/// kind of row is testable without a window.
///
/// **A key that does not apply to the selected row does nothing.** `a` on a running run is not
/// an error and not a guess at what was meant; the row's hint line only offers what applies.
enum ArchonKeyAction: Equatable {
    case none
    case toggleExpanded(runID: String)
    /// Open what a finished run produced: its pull request, or its branch.
    case open(ArchonRun)
    case decide(ArchonGateDecision, ArchonRun)
    case resume(ArchonRun)
    /// The first `c`: the row asks for a second before anything is sent.
    case armCancel(runID: String)
    case cancel(ArchonRun)
    case followLog(ArchonRun)
    case dismiss(ArchonRun)
    case focusComposer
    /// Open the searchable list of workflows Send can launch (#528).
    case pickWorkflow
}

enum ArchonKeys {
    /// The one key-to-action table. `key` is the character pressed (`"\r"` for Return, `"\u{7F}"`
    /// for Delete); `armedCancel` is the run a first `c` armed, if any.
    static func action(
        for key: Character, on run: ArchonRun?, armedCancel: String?
    ) -> ArchonKeyAction {
        if key == "/" { return .focusComposer }
        if key == "w" { return .pickWorkflow }
        guard let run else { return .none }
        switch key {
        case "\r":
            return run.isFinished ? .open(run) : .toggleExpanded(runID: run.id)
        case "a": return run.isAwaitingDecision ? .decide(.approve, run) : .none
        case "x": return run.isAwaitingDecision ? .decide(.reject, run) : .none
        case "r":
            return run.status == ArchonRunStatus.failed || run.isPaused ? .resume(run) : .none
        case "c":
            guard run.isRunning else { return .none }
            return armedCancel == run.id ? .cancel(run) : .armCancel(runID: run.id)
        case "l": return .followLog(run)
        case "\u{7F}", "\u{8}": return run.isFinished ? .dismiss(run) : .none
        default:
            guard let digit = key.wholeNumberValue, (1...9).contains(digit), run.isAwaitingDecision,
                let gate = run.gate, gate.decisions.indices.contains(digit - 1)
            else { return .none }
            return .decide(.declared(gate.decisions[digit - 1].id), run)
        }
    }

    /// The line `archon workflow logs` needs to follow a run in a terminal. Run from the run's own
    /// directory when it has one, as Archon resolves the project from the working directory.
    static func followLogLine(for run: ArchonRun) -> String {
        let command = "archon workflow logs \(run.id) --follow"
        guard let path = run.workingPath, !path.isEmpty else { return command }
        return "cd \(shellQuoted(path)) && \(command)"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

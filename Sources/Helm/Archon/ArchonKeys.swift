import Foundation

/// One row of the Archon drawer's list: an item in the attention queue, or a run.
enum ArchonDrawerRow: Equatable, Identifiable {
    case item(ArchonAttentionItem)
    case run(ArchonRun)

    /// Prefixed for the item, because a paused run and its queue item share a run id and the
    /// list scrolls and selects by this.
    var id: String {
        switch self {
        case let .item(item): "attention:" + item.runId
        case let .run(run): run.id
        }
    }
}

/// What a key does in the Archon drawer (#382), as a value: the view reads a key press, asks
/// this, and carries the answer out. Kept apart from SwiftUI so every key's meaning for every
/// kind of row is testable without a window.
///
/// **A key that does not apply to the selected row does nothing.** `a` on a running run is not
/// an error and not a guess at what was meant; the row's hint line only offers what applies.
enum ArchonKeyAction: Equatable {
    case none
    case toggleExpanded(rowID: String)
    /// Open what a finished run produced: its pull request, or its branch.
    case open(ArchonRun)
    /// Point the composer at one of an item's answers.
    case choose(ArchonChoice, ArchonAttentionItem)
    case resume(runID: String)
    /// The first `c`: the row asks for a second before anything is sent.
    case armCancel(runID: String)
    case cancel(ArchonRun)
    case followLog(runID: String, workingPath: String?)
    case dismiss(ArchonRun)
    case focusComposer
    /// Open the searchable list of workflows Send can launch (#528).
    case pickWorkflow
}

enum ArchonKeys {
    /// The one key-to-action table. `key` is the character pressed (`"\r"` for Return, `"\u{7F}"`
    /// for Delete); `armedCancel` is the run a first `c` armed, if any.
    static func action(
        for key: Character, on row: ArchonDrawerRow?, armedCancel: String?
    ) -> ArchonKeyAction {
        if key == "/" { return .focusComposer }
        if key == "w" { return .pickWorkflow }
        switch row {
        case nil: return .none
        case let .item(item): return action(for: key, on: item)
        case let .run(run): return action(for: key, on: run, armedCancel: armedCancel)
        }
    }

    /// An item's answers are its number keys, in Archon's order; `a` and `x` stay the approve
    /// and reject they always were, wherever an item offers those ids.
    private static func action(
        for key: Character, on item: ArchonAttentionItem
    )
        -> ArchonKeyAction
    {
        let choices = item.choices
        switch key {
        case "\r": return .toggleExpanded(rowID: ArchonDrawerRow.item(item).id)
        case "l": return .followLog(runID: item.runId, workingPath: item.context.workingPath)
        case "r": return item.isUnreadable ? .resume(runID: item.runId) : .none
        case "a", "x":
            let id = key == "a" ? "approve" : "reject"
            return choices.first { $0.id == id }.map { .choose($0, item) } ?? .none
        default:
            guard let digit = key.wholeNumberValue, (1...9).contains(digit),
                choices.indices.contains(digit - 1)
            else { return .none }
            return .choose(choices[digit - 1], item)
        }
    }

    private static func action(
        for key: Character, on run: ArchonRun, armedCancel: String?
    ) -> ArchonKeyAction {
        switch key {
        case "\r":
            return run.isFinished ? .open(run) : .toggleExpanded(rowID: run.id)
        case "r":
            // A paused run here is not in the queue: an answer recorded where nothing
            // continued it is the case `r` is for.
            return run.status == ArchonRunStatus.failed || run.isPaused
                ? .resume(runID: run.id) : .none
        case "c":
            guard run.isRunning else { return .none }
            return armedCancel == run.id ? .cancel(run) : .armCancel(runID: run.id)
        case "l": return .followLog(runID: run.id, workingPath: run.workingPath)
        case "\u{7F}", "\u{8}": return run.isFinished ? .dismiss(run) : .none
        default: return .none
        }
    }

    /// The line `archon workflow logs` needs to follow a run in a terminal. Run from the run's own
    /// directory when it has one, as Archon resolves the project from the working directory.
    static func followLogLine(runID: String, workingPath: String?) -> String {
        let command = "archon workflow logs \(runID) --follow"
        guard let path = workingPath, !path.isEmpty else { return command }
        return "cd \(shellQuoted(path)) && \(command)"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

import Foundation

/// ⌘⇧N's note (#289): what helm says when it cannot start one, and the day it is named after.
///
/// **Where a note lands and what it is called are benchd's now** (M5c, #459). `~/.prp` lives on
/// the agents' machine, so benchd resolves the workspace's store with prp's own resolver, registers
/// it as prp would when nothing has touched it yet, and creates `notes/<day>-note[-n].md` there
/// (`prp/note`, `daemon/crates/benchd/src/prp.rs`). What stays in helm is the operator's side:
/// which day it is for him, and the sentence he reads when it does not work.
///
/// `notes/` is the one directory in a store that is the operator's rather than an agent's: a
/// sibling of prp's own `plans/`, `research/`, `reviews/`. An agent is told in
/// `.claude/skills/helm-canvas/SKILL.md` to read what is in there when the operator names it and
/// never to write into it. That is a convention rather than a lock, and saying so is more honest
/// than implying helm could enforce it. It is also not what makes a file editable: `EditableFile`
/// judges the file in front of the canvas.
enum OperatorNote {
    /// Why a note could not be started. A named type rather than a bare `Error` so the sentence
    /// the operator reads is written here, once, beside the rule that produced it.
    enum Failure: Error, Equatable {
        /// No workspace is open, so there is no project whose store the note would belong to.
        case noWorkspace
        /// benchd could not be asked, or refused: its reason, in its words.
        case couldNotStart(String)
        /// Unreachable, and checked anyway — see `WorkbenchModel.newNote`.
        case notARecognisableNote(String)

        var sentence: String {
            switch self {
            case .noWorkspace:
                "Open a workspace first — a note lands in that project's ~/.prp store."
            case let .couldNotStart(reason):
                "Could not start a note: \(reason)"
            case let .notARecognisableNote(path):
                "benchd made \(path) but helm will not let you edit it. This is a bug."
            }
        }
    }

    /// The note's day as benchd names the file: `2026-08-07`, on the operator's calendar, since he
    /// is the one who will look for it by date.
    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// `en_US_POSIX`, because a note's filename must not change shape with the operator's region.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

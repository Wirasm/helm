import Foundation
import HelmWire

/// Which bench panes are working in which worktree, read from benchd's document: a terminal
/// pane's `cwd` is where benchd last saw its shell (M5b), and a pane with no reading yet falls
/// back to the directory its recorded agent started in. Nothing is asked of the panes.
enum WorktreeOccupants {
    struct Occupant: Equatable, Sendable {
        let cwd: String
        /// The pane's name when it has one (`claude · helm`), else its agent, else `shell`.
        let label: String
    }

    /// Every terminal pane in the document that says where it is: every workspace's bench and
    /// every drawer.
    static func occupants(of document: BenchDocument?) -> [Occupant] {
        guard let document else { return [] }
        let panes =
            document.workspaces.flatMap { $0.bench.columns }.flatMap(\.slots).flatMap(\.panes)
            + document.drawers.flatMap(\.panes)
        return panes.compactMap { pane in
            guard case let .terminal(agent, _, cwd) = pane.surface,
                let directory = cwd ?? agent?.cwd
            else { return nil }
            return Occupant(
                cwd: directory, label: pane.name.text ?? agent?.command ?? "shell")
        }
    }

    /// Each occupant goes to the deepest worktree it is inside, so a shell in
    /// `helm/.worktrees/drawer` counts for that worktree and not for `helm` around it.
    /// Keyed by worktree path; a worktree nobody is in has no key.
    static func assign(_ occupants: [Occupant], to worktreePaths: [String]) -> [String: [String]] {
        var byPath: [String: [String]] = [:]
        for occupant in occupants {
            let home =
                worktreePaths
                .filter {
                    occupant.cwd == $0 || occupant.cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
                }
                .max { $0.count < $1.count }
            if let home { byPath[home, default: []].append(occupant.label) }
        }
        return byPath
    }
}

import Foundation

/// UI state that belongs to one open workspace. Live terminal resources remain
/// owned by TerminalManager; UUIDs here only restore the in-process tab choice.
///
/// **The room-era keys were renamed, and that discards saved state deliberately.**
/// `selectedRoomID`, `roomsTab` and the room-keyed `composerDrafts` are persisted under
/// `helmWorkspaceContexts`, so renaming them means a previously-saved context no longer
/// decodes into the new shape and is dropped.
///
/// That is the intended outcome rather than an oversight. The alternative is a migration
/// that reads the old keys and maps them forward — but a room id is not a kild id, the
/// archives moved, and every mapped selection would point at something that no longer
/// exists. A shim would preserve the *shape* of the state while making its *contents*
/// wrong, which is worse than starting clean: the operator loses tab selections and
/// drafts once, visibly, instead of finding stale selections that silently resolve to
/// nothing.
struct WorkspaceContext: Codable, Equatable {
    var terminalSessionIDs: [UUID] = []
    var selectedTerminalID: UUID?
    var selectedKildID: String?
    var kildsTab: KildsTab = .live
    var historyQuery = ""
    var openArtifactPath: String?
    var expandedKilds: Set<String> = []
    var composerDrafts: [String: String] = [:]
    /// Resolved off the render path on open/switch. It is harmless to persist:
    /// git will refresh it when the workspace becomes active again.
    var branch: String?
    var branchResolved = false

    mutating func droppingDanglingSessionIDs(validIDs: Set<UUID>) {
        terminalSessionIDs = terminalSessionIDs.filter { validIDs.contains($0) }
        if let selectedTerminalID, !validIDs.contains(selectedTerminalID) {
            self.selectedTerminalID = nil
        }
    }
}

/// Which half of the sidebar is showing.
enum KildsTab: String, Codable, Equatable {
    /// Kilds the engine currently holds, including orphaned worktrees.
    case live
    /// Stopped kilds, from `GET /api/kilds/archive`.
    case history
}

enum WorkspaceContextStore {
    /// Unchanged. The key names the *container*, and the container's job did not change —
    /// only the shape inside it. Bumping the key would orphan the old blob on disk forever
    /// instead of letting it be overwritten by the first save.
    static let key = "helmWorkspaceContexts"

    /// A context that does not decode is dropped, not repaired.
    ///
    /// `decode` on the whole dictionary fails atomically if any entry is room-era, which
    /// means one stale workspace discards them all. That is acceptable and deliberate: the
    /// alternative is per-entry recovery, which would keep partially-migrated state around
    /// and make "did my context survive?" depend on which workspace you opened.
    static func load(
        from defaults: UserDefaults, validSessionIDs: Set<UUID> = []
    ) -> [String:
        WorkspaceContext]
    {
        guard let raw = defaults.string(forKey: key),
            var contexts = try? JSONDecoder().decode(
                [String: WorkspaceContext].self, from: Data(raw.utf8))
        else { return [:] }
        for path in contexts.keys {
            contexts[path]?.droppingDanglingSessionIDs(validIDs: validSessionIDs)
        }
        return contexts
    }

    static func save(_ contexts: [String: WorkspaceContext], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(contexts) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
    }
}

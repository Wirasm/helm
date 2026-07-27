import Foundation

/// UI state that belongs to one open workspace. Live terminal resources remain
/// owned by TerminalManager; UUIDs here only restore the in-process tab choice.
struct WorkspaceContext: Codable, Equatable {
    var terminalSessionIDs: [UUID] = []
    var selectedTerminalID: UUID?
    var selectedRoomID: String?
    var roomsTab: KildStore.RoomsTab = .live
    var openArtifactPath: String?
    var expandedRooms: Set<String> = []
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

enum WorkspaceContextStore {
    static let key = "helmWorkspaceContexts"

    static func load(from defaults: UserDefaults, validSessionIDs: Set<UUID> = []) -> [String: WorkspaceContext] {
        guard let raw = defaults.string(forKey: key),
              var contexts = try? JSONDecoder().decode([String: WorkspaceContext].self, from: Data(raw.utf8))
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

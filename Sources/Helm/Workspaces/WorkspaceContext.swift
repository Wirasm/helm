import Foundation

/// UI state that belongs to one open workspace. Live terminal resources remain
/// owned by TerminalManager; UUIDs here only restore the in-process tab choice.
///
/// **Removing the kild fields discards saved state, deliberately.** The kild selection,
/// tab, search query, fold state and per-agent drafts persisted under
/// `helmWorkspaceContexts`, so dropping them means a previously-saved context no longer
/// decodes and is thrown away.
///
/// That is the intended outcome. The alternative is a decoder that tolerates the old keys
/// and ignores them — which keeps the file readable while making a promise the app can no
/// longer keep, since nothing here can act on a kild id any more. Losing terminal tab
/// selections once, visibly, beats carrying a shape whose contents refer to a subsystem
/// that no longer exists.
struct WorkspaceContext: Codable, Equatable {
    var terminalSessionIDs: [UUID] = []
    var selectedTerminalID: UUID?
    var openArtifactPath: String?
    /// Resolved off the render path on open/switch. It is harmless to persist:
    /// git will refresh it when the workspace becomes active again.
    var branch: String?
    var branchResolved = false
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
    ///
    /// **Persisted session ids survive load.** This used to filter them against the ids
    /// live *in this process*, which at launch is none — so a cold start always restored
    /// zero terminals and the persistence was neutered by its own loader. The ids are the
    /// only record of how many terminals a workspace had and which was selected;
    /// `TerminalManager.activate(workspacePath:selectedID:restoring:)` rebuilds the row
    /// under them on first visit. Filtering here is what made a relaunch cost every
    /// terminal in every workspace.
    static func load(from defaults: UserDefaults) -> [String: WorkspaceContext] {
        guard let raw = defaults.string(forKey: key),
            let contexts = try? JSONDecoder().decode(
                [String: WorkspaceContext].self, from: Data(raw.utf8))
        else { return [:] }
        return contexts
    }

    static func save(_ contexts: [String: WorkspaceContext], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(contexts) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
    }
}

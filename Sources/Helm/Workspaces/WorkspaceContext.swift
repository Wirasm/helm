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
    /// The three legacy fields. **Kept, and still read forever.** They are the migration
    /// source for a blob written before there was a bench (`Workbench.migrating(from:)`);
    /// dropping them would cost an operator relaunching onto this build the tab row
    /// position 1 bought. Nothing writes them any more — the bench carries all three.
    var terminalSessionIDs: [UUID] = []
    var selectedTerminalID: UUID?
    var openArtifactPath: String?
    /// Resolved off the render path on open/switch. It is harmless to persist:
    /// git will refresh it when the workspace becomes active again.
    var branch: String?
    var branchResolved = false
    /// The pane arrangement, carrying the canvas source with it — which is what finally
    /// lets a **URL** canvas be restored, where `openArtifactPath` could only ever hold a
    /// file path.
    ///
    /// `Optional` is not a style choice. **Measured:** a non-optional field with a
    /// default still throws `keyNotFound` when its key is missing, so `var workbench =
    /// Workbench.empty` would make every blob written by an older build fail to decode —
    /// and, per the note below, discard every workspace's context along with it.
    var workbench: Workbench?

    /// Spelled out because the hand-written `init(from:)` below suppresses the
    /// synthesized memberwise one.
    init(
        terminalSessionIDs: [UUID] = [], selectedTerminalID: UUID? = nil,
        openArtifactPath: String? = nil, branch: String? = nil, branchResolved: Bool = false,
        workbench: Workbench? = nil
    ) {
        self.terminalSessionIDs = terminalSessionIDs
        self.selectedTerminalID = selectedTerminalID
        self.openArtifactPath = openArtifactPath
        self.branch = branch
        self.branchResolved = branchResolved
        self.workbench = workbench
    }

    /// Hand-written because the synthesized decoder is all-or-nothing at TWO levels, and
    /// both were measured against this exact shape:
    ///
    /// 1. `WorkspaceContextStore.load` decodes `[String: WorkspaceContext]` in one call,
    ///    so ONE bad entry discards EVERY workspace's context — including the terminal
    ///    restore position 1 shipped.
    /// 2. A corrupt value in ONE field throws for the whole entry, and therefore for the
    ///    whole dictionary. A malformed bench would take the terminals down with it.
    ///
    /// So every field is read with `try?` and falls back to its default, and `workbench`
    /// in particular degrades to nil — which sends restore down the migration path rather
    /// than losing the workspace.
    ///
    /// Note the idiom: `try?` over `decodeIfPresent` yields a **double** optional.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalSessionIDs =
            ((try? container.decodeIfPresent([UUID].self, forKey: .terminalSessionIDs)) ?? nil)
            ?? []
        selectedTerminalID =
            (try? container.decodeIfPresent(UUID.self, forKey: .selectedTerminalID)) ?? nil
        openArtifactPath =
            (try? container.decodeIfPresent(String.self, forKey: .openArtifactPath)) ?? nil
        branch = (try? container.decodeIfPresent(String.self, forKey: .branch)) ?? nil
        branchResolved =
            ((try? container.decodeIfPresent(Bool.self, forKey: .branchResolved)) ?? nil) ?? false
        workbench = (try? container.decodeIfPresent(Workbench.self, forKey: .workbench)) ?? nil
    }
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

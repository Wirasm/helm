import Foundation

/// The open-workspace list as it survives a relaunch. `@AppStorage` cannot hold an
/// array, so the list lives as a JSON string under `helmWorkspaces` and the current
/// selection as a bare path under `helmSelectedWorkspace` — both in the same
/// `UserDefaults` an `@AppStorage` view property would use.
enum WorkspacePersistence {
    static let listKey = "helmWorkspaces"
    static let selectionKey = "helmSelectedWorkspace"

    /// A missing or corrupt blob is an empty list — never a crash, never a partial
    /// list: the operator reopens the folders, which costs one ⌘⇧O each.
    static func load(from defaults: UserDefaults) -> [Workspace] {
        guard
            let raw = defaults.string(forKey: listKey),
            let decoded = try? JSONDecoder().decode([Workspace].self, from: Data(raw.utf8))
        else { return [] }
        return decoded
    }

    /// Encoding an array of strings cannot fail; the `try?` exists only because the
    /// signature says it can, and dropping a save is still better than trapping.
    static func save(_ workspaces: [Workspace], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: listKey)
    }

    /// The remembered selection, but only if it is still an open workspace.
    static func loadSelection(from defaults: UserDefaults, in workspaces: [Workspace]) -> Workspace?
    {
        guard let path = defaults.string(forKey: selectionKey) else { return nil }
        let remembered = Workspace(path: path)
        return workspaces.contains(remembered) ? remembered : nil
    }

    static func saveSelection(_ workspace: Workspace?, to defaults: UserDefaults) {
        if let workspace {
            defaults.set(workspace.path.value, forKey: selectionKey)
        } else {
            defaults.removeObject(forKey: selectionKey)
        }
    }
}

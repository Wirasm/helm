import AppKit
import Foundation

// MARK: - Store discovery (pure, testable)

/// One artifact file inside a project store: its URL and the store-relative
/// subpath the browser row displays (e.g. "plans/foo.diagrams.md").
struct ArtifactFile: Equatable {
    let url: URL
    let relativePath: String
    let modified: Date
}

/// One per-project artifact store (`~/.prp/<key>/`), identified by its
/// `project.json`.
struct ArtifactStore: Equatable, Identifiable {
    /// Directory name under the artifact root.
    let key: String
    /// Display name from project.json's "name", falling back to the key.
    let name: String
    /// The repo root from project.json's "path" — the link from an open workspace
    /// folder back to its store (`WorkspaceStore`). nil when the file omits it.
    let projectPath: String?
    let root: URL

    var id: String { key }
}

/// Walks the artifact root (`~/.prp` in production, a fixture directory in
/// tests). The filesystem IS the artifact API — no engine calls, just a cheap
/// directory walk on every popover open.
enum ArtifactStoreDiscovery {
    /// Directory levels walked below a store root — stores keep artifacts one
    /// subdirectory deep (plans/, reviews/, …); the listing stays flat.
    static let maxDepth = 2

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".prp")
    }

    /// Stores under `root` (subdirectories containing project.json), sorted by
    /// name. Missing/unreadable directories yield [].
    static func discoverStores(under root: URL) -> [ArtifactStore] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var stores: [ArtifactStore] = []
        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let projectJSON = dir.appendingPathComponent("project.json")
            guard fm.fileExists(atPath: projectJSON.path) else { continue }
            let registered = registration(from: projectJSON)
            stores.append(
                ArtifactStore(
                    key: dir.lastPathComponent,
                    name: registered.name ?? dir.lastPathComponent,
                    projectPath: registered.path,
                    root: dir
                )
            )
        }
        return stores.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The store's artifacts as a flat list, newest first, with store-relative
    /// display names.
    static func artifactFiles(in root: URL) -> [ArtifactFile] {
        var files: [ArtifactFile] = []
        collectFiles(in: root, storeRoot: root, depth: 1, into: &files)
        return files.sorted { $0.modified > $1.modified }
    }

    /// A store's registration — `{"path": ..., "name": ...}`, written by prp. One
    /// parse for both fields: "name" titles the picker row, "path" is what a
    /// workspace folder is matched against.
    static func registration(from projectJSON: URL) -> (path: String?, name: String?) {
        guard
            let data = try? Data(contentsOf: projectJSON),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        func nonEmpty(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return (nonEmpty("path"), nonEmpty("name"))
    }

    /// True for files the browser lists: .md/.html artifacts, never dotfiles
    /// or the store's own project.json.
    static func isArtifactFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), name != "project.json" else { return false }
        return RenderableFile.isRenderable(url)
    }

    private static func collectFiles(
        in directory: URL, storeRoot: URL, depth: Int, into files: inout [ArtifactFile]
    ) {
        guard depth <= maxDepth else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )
        else { return }

        for entry in entries {
            guard !entry.lastPathComponent.hasPrefix(".") else { continue }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                collectFiles(in: entry, storeRoot: storeRoot, depth: depth + 1, into: &files)
            } else if isArtifactFile(entry) {
                files.append(
                    ArtifactFile(
                        url: entry,
                        relativePath: relativePath(of: entry, under: storeRoot),
                        modified: values?.contentModificationDate ?? .distantPast
                    )
                )
            }
        }
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath)
            ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }
}

import AppKit
import SwiftUI

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
            stores.append(
                ArtifactStore(
                    key: dir.lastPathComponent,
                    name: displayName(from: projectJSON) ?? dir.lastPathComponent,
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

    /// "name" from a store's project.json ({"path": ..., "name": ...}).
    static func displayName(from projectJSON: URL) -> String? {
        guard
            let data = try? Data(contentsOf: projectJSON),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["name"] as? String,
            !name.isEmpty
        else { return nil }
        return name
    }

    /// True for files the browser lists: .md/.html artifacts, never dotfiles
    /// or the store's own project.json.
    static func isArtifactFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), name != "project.json" else { return false }
        return ArtifactHTML.isMarkdown(url) || ArtifactHTML.isHTML(url)
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
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }
}

// MARK: - View

/// The artifact browser popover: pick a project, see its artifacts flat and
/// newest-first, click one to open it. One "Browse…" escape hatch into the
/// NSOpenPanel for anything outside the stores. Anchored to the strip's
/// artifact button; ⌘O opens this. The listing refreshes on every open.
struct ArtifactBrowser: View {
    @ObservedObject var model: ArtifactPaneModel
    let onDismiss: () -> Void
    /// Overridable so previews/tests could point elsewhere; production uses ~/.prp.
    var root: URL = ArtifactStoreDiscovery.defaultRoot

    /// Last-selected project key, remembered across popover opens and relaunch.
    @AppStorage("artifactBrowserStore") private var selectedKey = ""
    @State private var stores: [ArtifactStore] = []
    @State private var files: [ArtifactFile] = []

    var body: some View {
        VStack(spacing: 0) {
            if stores.isEmpty {
                emptyState
            } else {
                Picker("Project", selection: $selectedKey) {
                    ForEach(stores) { store in
                        Text(store.name).tag(store.key)
                    }
                }
                .labelsHidden()
                .padding(10)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(files, id: \.url) { file in
                            fileRow(file)
                        }
                        if files.isEmpty {
                            Text("No artifacts in this project yet.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 420)
            }

            Divider()
            browseRow
        }
        .frame(width: 380)
        .onAppear(perform: refresh)
        .onChange(of: selectedKey) { _, _ in refreshFiles() }
    }

    private var selectedStore: ArtifactStore? {
        stores.first { $0.key == selectedKey }
    }

    private func refresh() {
        stores = ArtifactStoreDiscovery.discoverStores(under: root)
        if selectedStore == nil {
            selectedKey = stores.first?.key ?? ""
        }
        refreshFiles()
    }

    private func refreshFiles() {
        files = selectedStore.map { ArtifactStoreDiscovery.artifactFiles(in: $0.root) } ?? []
    }

    // MARK: Rows

    private func fileRow(_ file: ArtifactFile) -> some View {
        Button {
            model.open(file.url)
            onDismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(file.relativePath)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(BrowserRowButtonStyle())
    }

    private var browseRow: some View {
        Button {
            onDismiss()
            model.presentOpenPanel(startingAt: selectedStore?.root)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("Browse…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(BrowserRowButtonStyle())
    }

    private var emptyState: some View {
        Text("No artifact stores found — agents write artifacts to ~/.prp/<project>/ (plans, research, reviews) and they show up here.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }
}

/// Hover-highlighted row, list-style, without dragging in a full List.
private struct BrowserRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        configuration.isPressed
                            ? Color(nsColor: .selectedControlColor).opacity(0.7)
                            : hovering
                                ? Color(nsColor: .selectedControlColor).opacity(0.4)
                                : .clear
                    )
            )
            .onHover { hovering = $0 }
    }
}

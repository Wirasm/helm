import AppKit
import SwiftUI

// MARK: - Store discovery (pure, testable)

/// One artifact file inside a project store, with everything the browser row
/// needs precomputed (relative subpath for display, mtime for sorting/age).
struct ArtifactFile: Equatable {
    let url: URL
    /// Path relative to the store root, e.g. "plans/foo.diagrams.md".
    let relativePath: String
    let modified: Date
}

/// One per-project artifact store (`~/.prp/<key>/`), identified by its
/// `project.json`. Files are pre-sorted newest-first and capped.
struct ArtifactStore: Equatable {
    /// Directory name under the artifact root.
    let key: String
    /// Display name from project.json's "name", falling back to the key.
    let name: String
    let root: URL
    /// Newest-first, capped at `ArtifactStoreDiscovery.fileCap`.
    let files: [ArtifactFile]
    /// True when the cap truncated the listing (more files on disk).
    let hasMore: Bool
}

/// Walks the artifact root (`~/.prp` in production, a fixture directory in
/// tests) and builds the store listing. The filesystem IS the artifact API —
/// no engine calls, just a cheap capped directory walk on every popover open.
enum ArtifactStoreDiscovery {
    /// Rows shown per store before the "Browse folder…" escape hatch.
    static let fileCap = 15
    /// Directory levels walked below a store root (plans/a/b/x.md is depth 3).
    static let maxDepth = 3

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".prp")
    }

    /// Stores under `root` (subdirectories containing project.json), sorted by
    /// most recent artifact activity. Missing/unreadable directories yield [].
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
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let projectJSON = dir.appendingPathComponent("project.json")
            guard fm.fileExists(atPath: projectJSON.path) else { continue }

            var files: [ArtifactFile] = []
            collectFiles(in: dir, storeRoot: dir, depth: 1, into: &files)
            files.sort { $0.modified > $1.modified }

            stores.append(
                ArtifactStore(
                    key: dir.lastPathComponent,
                    name: displayName(from: projectJSON) ?? dir.lastPathComponent,
                    root: dir,
                    files: Array(files.prefix(fileCap)),
                    hasMore: files.count > fileCap
                )
            )
        }
        // Most recently active project first; empty stores sink to the bottom.
        stores.sort {
            ($0.files.first?.modified ?? .distantPast)
                > ($1.files.first?.modified ?? .distantPast)
        }
        return stores
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
        return ArtifactRenderer.isMarkdown(url) || ArtifactRenderer.isHTML(url)
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

// MARK: - Recents (pure codec, testable)

/// Encode/decode + maintenance for the recently-opened artifact list that
/// ArtifactPaneModel persists as JSON in @AppStorage. Pure functions so the
/// codec, dedupe/cap, and missing-file pruning are unit-testable.
enum ArtifactRecents {
    static let cap = 8

    static func decode(_ json: String) -> [String] {
        guard
            let data = json.data(using: .utf8),
            let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return paths
    }

    static func encode(_ paths: [String]) -> String {
        guard
            let data = try? JSONEncoder().encode(paths),
            let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    /// Most-recent-first: `path` moves to the front, duplicates collapse, and
    /// the list is capped.
    static func adding(_ path: String, to paths: [String]) -> [String] {
        var result = paths.filter { $0 != path }
        result.insert(path, at: 0)
        return Array(result.prefix(cap))
    }

    /// Drops entries whose file no longer exists (artifacts get moved and
    /// deleted out from under us; stale rows would open to an error notice).
    static func pruned(
        _ paths: [String],
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        paths.filter(exists)
    }
}

// MARK: - Filter matching (pure, testable)

/// Fuzzy-ish matching for the browser's filter field: case-insensitive, every
/// whitespace-separated token must appear somewhere in the candidate path —
/// so "plan diagrams" finds plans/foo.diagrams.md.
enum ArtifactFilter {
    static func matches(query: String, candidate: String) -> Bool {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let haystack = candidate.lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

// MARK: - Relative age (pure, testable)

/// Compact relative mtime for browser rows: "now", "5m ago", "2h ago",
/// "3d ago", then an absolute "Jun 2" beyond a week.
enum ArtifactAge {
    static func label(for date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

// MARK: - View

/// The artifact browser popover: filter field over Recents and one section per
/// project store, with "Browse…" escape hatches into the old NSOpenPanel.
/// Anchored to the strip's artifact button; ⌘O opens this instead of the
/// panel. The listing refreshes on every open (cheap capped walk).
struct ArtifactBrowser: View {
    @ObservedObject var model: ArtifactPaneModel
    let onDismiss: () -> Void
    /// Overridable so previews/tests could point elsewhere; production uses ~/.prp.
    var root: URL = ArtifactStoreDiscovery.defaultRoot

    @State private var query = ""
    @State private var stores: [ArtifactStore] = []
    @State private var recents: [URL] = []
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter artifacts", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($filterFocused)
                .onSubmit(openTopMatch)
                .padding(10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if stores.isEmpty, filteredRecents.isEmpty {
                        emptyState
                    }
                    recentsSection
                    storeSections
                    browseAllRow
                }
                .padding(8)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 380)
        .onAppear {
            stores = ArtifactStoreDiscovery.discoverStores(under: root)
            recents = model.recentArtifactPaths.map { URL(fileURLWithPath: $0) }
            filterFocused = true
        }
    }

    // MARK: Filtering

    private var filteredRecents: [URL] {
        recents.filter { ArtifactFilter.matches(query: query, candidate: $0.lastPathComponent) }
    }

    private func filteredFiles(of store: ArtifactStore) -> [ArtifactFile] {
        store.files.filter { ArtifactFilter.matches(query: query, candidate: $0.relativePath) }
    }

    /// Return in the filter field opens the first visible row: recents first,
    /// then the stores in listed order.
    private var topMatch: URL? {
        if let recent = filteredRecents.first { return recent }
        for store in stores {
            if let file = filteredFiles(of: store).first { return file.url }
        }
        return nil
    }

    private func openTopMatch() {
        guard let url = topMatch else { return }
        open(url)
    }

    private func open(_ url: URL) {
        model.open(url)
        onDismiss()
    }

    // MARK: Sections

    @ViewBuilder
    private var recentsSection: some View {
        let matches = filteredRecents
        if !matches.isEmpty {
            sectionHeader("Recents")
            ForEach(matches, id: \.self) { url in
                row(
                    title: url.lastPathComponent,
                    subtitle: abbreviatedParent(of: url),
                    icon: "clock"
                ) {
                    open(url)
                }
            }
        }
    }

    @ViewBuilder
    private var storeSections: some View {
        ForEach(stores, id: \.key) { store in
            let matches = filteredFiles(of: store)
            if !matches.isEmpty || query.isEmpty {
                sectionHeader(store.name)
                ForEach(matches, id: \.url) { file in
                    row(
                        title: file.relativePath,
                        subtitle: ArtifactAge.label(for: file.modified),
                        icon: "doc.text"
                    ) {
                        open(file.url)
                    }
                }
                if store.hasMore || matches.isEmpty || query.isEmpty {
                    browseRow(title: "Browse folder…", directory: store.root)
                }
            }
        }
    }

    private var browseAllRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
                .padding(.vertical, 4)
            browseRow(title: "Browse files…", directory: nil)
        }
    }

    private var emptyState: some View {
        Text("No artifact stores found — agents write artifacts to ~/.prp/<project>/ (plans, research, reviews) and they show up here.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    // MARK: Row building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(
        title: String, subtitle: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(BrowserRowButtonStyle())
    }

    private func browseRow(title: String, directory: URL?) -> some View {
        Button {
            onDismiss()
            model.presentOpenPanel(startingAt: directory)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(BrowserRowButtonStyle())
    }

    private func abbreviatedParent(of url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent.hasPrefix(home)
            ? "~" + parent.dropFirst(home.count)
            : parent
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

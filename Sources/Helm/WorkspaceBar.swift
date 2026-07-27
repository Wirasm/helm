import AppKit
import SwiftUI

/// The window-level workspace switcher. Context tabs are deliberately quiet:
/// attention will colour this existing element in a later observe slice.
struct WorkspaceBar: View {
    @ObservedObject var store: KildStore
    let select: (Workspace) -> Void
    let open: (Workspace) -> Void
    let close: (Workspace) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        Button { select(workspace) } label: {
                            HStack(spacing: 5) {
                                Text("⌃\(index + 1)").foregroundStyle(.secondary)
                                Text(workspace.name).fontWeight(store.selectedWorkspace == workspace ? .semibold : .regular)
                                if let branch = store.contexts[workspace.path]?.branch {
                                    Text(branch).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(store.selectedWorkspace == workspace ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Close Workspace") { close(workspace) }
                            Button("Copy Path") { Pasteboard.copy(workspace.path) }
                        }
                        .task(id: workspace.path) { await resolveBranch(for: workspace) }
                    }
                }
            }
            Button(action: openWorkspace) { Image(systemName: "plus") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Open workspace (⌘⇧O)")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.bar)
        .onReceive(NotificationCenter.default.publisher(for: .helmOpenWorkspace)) { _ in openWorkspace() }
    }

    private func openWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to work in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(Workspace(url: url))
    }

    private func resolveBranch(for workspace: Workspace) async {
        guard store.contexts[workspace.path]?.branchResolved != true else { return }
        let branch = await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", workspace.path, "branch", "--show-current"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.value
        store.cacheBranch(branch, for: workspace)
    }
}

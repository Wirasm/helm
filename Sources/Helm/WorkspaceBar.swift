import AppKit
import SwiftUI

/// The window-level workspace switcher.
///
/// Deliberately quiet. It names the open folders, marks which one is active, and shows each
/// one's git branch when there is one — nothing that needs watching. Anything that wants
/// attention belongs somewhere it can be acted on, not in a strip above everything else.
struct WorkspaceBar: View {
    @ObservedObject var model: WorkspaceModel
    let select: (Workspace) -> Void
    let open: (Workspace) -> Void
    let close: (Workspace) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.workspaces.enumerated()), id: \.element.id) {
                        index, workspace in
                        tab(index: index, workspace: workspace)
                    }
                }
            }
            Button(action: openWorkspace) { Image(systemName: "plus") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Open workspace (⌘⇧O)")
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.bar)
        .onReceive(NotificationCenter.default.publisher(for: .helmOpenWorkspace)) { _ in
            openWorkspace()
        }
    }

    /// Hoisted out of `body` because the type-checker gave up on the nested conditionals
    /// when this was inline — a real constraint, not a style preference.
    @ViewBuilder
    private func tab(index: Int, workspace: Workspace) -> some View {
        let isSelected = model.selectedWorkspace == workspace
        Button {
            select(workspace)
        } label: {
            HStack(spacing: 5) {
                Text("⌃\(index + 1)").foregroundStyle(.secondary)
                Text(workspace.name).fontWeight(isSelected ? .semibold : .regular)
                if let branch = model.contexts[workspace.path]?.branch {
                    Text(branch).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : .clear,
                in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Close Workspace") { close(workspace) }
            Button("Copy Path") { Pasteboard.copy(workspace.path) }
        }
        .task(id: workspace.path) { await resolveBranch(for: workspace) }
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

    /// Asked once per workspace and cached, resolved off the render path. `branchResolved`
    /// is set whether or not a branch came back, so a folder that is not a repository is
    /// asked once rather than on every appearance.
    private func resolveBranch(for workspace: Workspace) async {
        guard model.contexts[workspace.path]?.branchResolved != true else { return }
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
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.value
        model.cacheBranch(branch, for: workspace)
    }
}

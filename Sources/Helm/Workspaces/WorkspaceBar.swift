import AppKit
import SwiftUI

/// The window-level workspace switcher.
///
/// Deliberately quiet. It names the open folders, marks which one is active, and shows each
/// one's git branch when there is one — nothing that needs watching. Anything that wants
/// attention belongs somewhere it can be acted on, not in a strip above everything else.
///
/// The board's dot is the one exception, and it earns it by being the only thing here you
/// cannot learn without leaving: whether a workspace you are *not* looking at has an agent
/// waiting on you. It is still state on an existing element, never anything that pops.
struct WorkspaceBar: View {
    @ObservedObject var model: WorkspaceModel
    /// The board's marks, owned by the Board slice and observed the way `RootView` observes
    /// `TerminalManager`. The bar renders a dot; it does not learn what a registry is.
    @ObservedObject private var board = BoardModel.shared
    let select: (Workspace) -> Void
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
            Button {
                Actions.perform(.local(.openWorkspacePanel))
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain).foregroundStyle(Color.textMuted)
            // Rendered from the map rather than typed. This tooltip said ⌘⇧O while the
            // status bar said ⇧⌘O — macOS prints modifiers ⌃⌥⇧⌘, so the bar was right
            // and one window disagreed with itself about one key (#149).
            .help(
                KeyGlyph.binding(for: .local(.openWorkspacePanel))
                    .map { "Open workspace (\($0))" }
                    ?? "Open workspace")
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(Color.textPrimary)
        .background(ChromeBackground())
        .task { await board.poll() }
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
                Text("⌃\(index + 1)").foregroundStyle(Color.textMuted)
                AgentDot(presence: board.presence[workspace.path.value])
                Text(workspace.name).fontWeight(isSelected ? .semibold : .regular)
                if let branch = model.branches[workspace.path] {
                    Text(branch).foregroundStyle(Color.textMuted).lineLimit(1)
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                isSelected ? Color.selection : .clear,
                in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Close Workspace") { close(workspace) }
            Button("Copy Path") { Pasteboard.copy(workspace.path.value) }
        }
        // Keyed on selection so the branch is asked again when the tab appears and whenever it
        // is switched to or away from (#379). `ForEach` already keys the tab by workspace.
        .task(id: isSelected) { await model.refreshBranch(for: workspace) }
    }
}

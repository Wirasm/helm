import AppKit
import SwiftUI

/// The window-level workspace switcher.
///
/// Deliberately quiet. It names the open folders, marks which one is active, and shows each
/// one's git branch when there is one — nothing that needs watching. Anything that wants
/// attention belongs somewhere it can be acted on, not in a strip above everything else.
///
/// The workspace mark is the one exception, and it earns it by being the only thing here you
/// cannot learn without leaving: whether a workspace you are *not* looking at has an agent that
/// needs you (`WorkspaceMark`). It is still state on an existing element, never anything that
/// pops.
struct WorkspaceBar: View {
    @ObservedObject var model: WorkspaceModel
    /// What benchd last said about every pane's agent: the marks are read off it, so the bar
    /// redraws when it changes and keeps nothing of its own.
    @ObservedObject private var foregrounds = TerminalManager.shared.foregrounds
    /// Which workspace each terminal is in: a pane moved to another workspace takes its mark
    /// along.
    @ObservedObject private var terminals = TerminalManager.shared
    @ObservedObject private var keymap = Keymap.shared
    /// Where a dragged tab goes (#178): a workspace tab reorders the bar, and a pane's tab dropped
    /// here moves to that workspace. The bar reports its frames and its own tabs' drags; the
    /// workbench resolves and sends (`WorkspaceDrop`).
    let workbench: WorkbenchModel
    let select: (Workspace) -> Void
    let close: (Workspace) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let marks = WorkspaceMark.of(TerminalManager.shared)
                    ForEach(Array(model.workspaces.enumerated()), id: \.element.id) {
                        index, workspace in
                        tab(index: index, workspace: workspace, mark: marks[workspace.path.value])
                    }
                }
            }
            Button {
                Actions.perform(.local(.openWorkspacePanel))
            } label: {
                Image(systemName: "plus").frame(width: 20, height: 20)
            }
            .buttonStyle(.chrome).foregroundStyle(Color.textMuted)
            // Rendered from the map rather than typed. This tooltip said ⌘⇧O while the
            // status bar said ⇧⌘O — macOS prints modifiers ⌃⌥⇧⌘, so the bar was right
            // and one window disagreed with itself about one key (#149).
            .help(
                KeyGlyph.binding(for: .local(.openWorkspacePanel), in: keymap.table)
                    .map { "Open workspace (\($0))" }
                    ?? "Open workspace")
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(Color.textPrimary)
        .background(ChromeBackground())
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(BenchDrag.space))
        } action: {
            workbench.drag.bar.strip = $0
        }
    }

    /// Hoisted out of `body` because the type-checker gave up on the nested conditionals
    /// when this was inline — a real constraint, not a style preference.
    @ViewBuilder
    private func tab(index: Int, workspace: Workspace, mark: WorkspaceMark?) -> some View {
        let isSelected = model.selectedWorkspace == workspace
        Button {
            select(workspace)
        } label: {
            HStack(spacing: 5) {
                Text("⌃\(index + 1)").foregroundStyle(Color.textMuted)
                AgentDot(mark: mark)
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
        .buttonStyle(.chrome)
        .modifier(DraggableWorkspaceTab(workbench: workbench, path: workspace.path))
        .contextMenu {
            Button("Close Workspace") { close(workspace) }
            Button("Copy Path") { Pasteboard.copy(workspace.path.value) }
        }
        // Keyed on selection so the branch is asked again when the tab appears and whenever it
        // is switched to or away from (#379). `ForEach` already keys the tab by workspace.
        .task(id: isSelected) { await model.refreshBranch(for: workspace) }
    }
}

/// A workspace tab reports where it is and can be dragged along the bar (#178), the way a pane's
/// tab can (`SlotTabStrip`): four points of travel before it starts, so a click stays a click, and
/// simultaneous with the button so its tap is not held back.
private struct DraggableWorkspaceTab: ViewModifier {
    let workbench: WorkbenchModel
    let path: WorkspacePath

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(BenchDrag.space))
                    .onChanged { workbench.dragTab(.workspace(path), to: $0.location) }
                    .onEnded { workbench.dropTab(.workspace(path), at: $0.location) }
            )
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(BenchDrag.space))
            } action: {
                workbench.drag.bar.tabs[path] = $0
            }
            .onDisappear {
                workbench.drag.bar.tabs[path] = nil
                workbench.drag.abandon(.workspace(path))
            }
    }
}

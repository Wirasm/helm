import AppKit
import SwiftUI

/// The window-level workspace switcher, and the one place attention is countable.
///
/// The workspace tabs stay deliberately quiet. What is loud is the waiting count, and it
/// lives here for a specific reason: `docs/escalation.md` requires that helm answer *"how
/// many agents are blocked on me right now?"* **at a glance**, and states that a list is not
/// enough. Dots on sidebar rows are a list — they tell you where attention is once you are
/// already looking at the sidebar, which is the failure mode that doc names. The bar is
/// visible regardless of which kild is selected, or whether the sidebar is in view at all.
struct WorkspaceBar: View {
    @ObservedObject var store: KildStore
    let select: (Workspace) -> Void
    let open: (Workspace) -> Void
    let close: (Workspace) -> Void
    /// Scroll the observe column to the first waiting agent and open its fold.
    ///
    /// The count is the entry point and the list is the follow-through — the order the doc
    /// asks for. Without this the badge tells you a number and leaves you to hunt.
    var revealWaiting: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) {
                        index, workspace in
                        Button {
                            select(workspace)
                        } label: {
                            HStack(spacing: 5) {
                                Text("⌃\(index + 1)").foregroundStyle(.secondary)
                                Text(workspace.name).fontWeight(
                                    store.selectedWorkspace == workspace ? .semibold : .regular)
                                if let branch = store.contexts[workspace.path]?.branch {
                                    Text(branch).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(
                                store.selectedWorkspace == workspace
                                    ? Color.accentColor.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
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

            Spacer(minLength: 8)

            // Scoped to the open workspace rather than every kild on the machine: the count
            // has to mean "waiting on you, here", or switching workspaces would leave a
            // number on screen that refers to somewhere you are not looking.
            WaitingBadge(count: store.waitingCount, reveal: revealWaiting)

            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.bar)
        .onReceive(NotificationCenter.default.publisher(for: .helmOpenWorkspace)) { _ in
            openWorkspace()
        }
    }

    /// Kild count and spend for the open workspace.
    ///
    /// **Both halves read the same scoped list.** Counting from `shownGroups` while summing
    /// cost from `cockpit.kilds` would put a workspace-scoped number beside a machine-wide
    /// one in the same sentence — "2 kilds · $47.10", where the money is from every project
    /// you have ever run. Two facts of different scope reading as one is the kind of wrong
    /// nobody questions, because the sentence is grammatical.
    ///
    /// Orphans are excluded from the count deliberately: they have no agents and no spend,
    /// and they have their own group in the column. "4 kilds" meaning four things you are
    /// working in is more useful than "120 kilds" meaning four plus the abandoned.
    ///
    /// Cost is omitted rather than shown as `$0.00` when the costly half has not arrived.
    /// A zero would be a claim helm cannot support — "nothing spent" and "not measured" are
    /// different facts, and on a number that only goes up the difference is the whole signal.
    private var summary: String {
        let live = store.shownGroups[.live] ?? []
        let spend = live.compactMap(\.totals?.cost).reduce(0, +)
        let label = "\(live.count) kild\(live.count == 1 ? "" : "s")"
        return spend > 0 ? "\(label) · $\(String(format: "%.2f", spend))" : label
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
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.value
        store.cacheBranch(branch, for: workspace)
    }
}

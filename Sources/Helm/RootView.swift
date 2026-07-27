import Inject
import SwiftUI
/// helm's one permanent surface — the ⌘T two-faces model is gone. Three panes:
///
/// - LEFT: the observe/steer column (engine health, workspaces, Live/History
///   rooms) — `SidebarColumn` over the shared `KildStore`.
/// - CENTER: the terminal workspace, always visible, never swapped or hidden —
///   the operator (pi/claude/codex) lives here and steers kild via its own
///   skill/extension. Never below 480pt of comfort.
/// - RIGHT: ONE shared dock. A selected room wins it (RoomDetailView); with no
///   selection it shows the open artifact; with neither it collapses away.
///   Esc (or deselecting) hands the dock back to the artifact, then closes it.
///
/// The ptys survive any of this churn — the shells live app-level in
/// TerminalManager, outside the view lifecycle (see docs/SPIKE.md).
struct RootView: View {
    /// Hot reload: `.enableInjection()` below redraws this view when
    /// InjectionNext swaps a recompiled build of it into the running app.
    /// Both are no-ops in release (docs/VENDORED.md).
    @ObserveInjection private var inject
    @StateObject private var store = KildStore()
    @StateObject private var artifact = ArtifactPaneModel()
    /// The artifact browser popover (anchored to the strip's artifact button);
    /// state lives here so the ⌘O notification can toggle it.
    @State private var showBrowser = false

    /// Sticky dock width. HSplitView has no divider persistence of its own, so
    /// helm does it: a GeometryReader observes the dock's live width into
    /// @AppStorage, and every (re)insertion restores it via `idealWidth` —
    /// chosen over a custom splitter, which would be far more code for the same
    /// behavior (HSplitView honors idealWidth whenever a pane appears).
    @AppStorage("helmDockWidth") private var dockWidth = 560.0

    /// The ONE engine poller — app level, shared by sidebar and dock alike.
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HSplitView {
            SidebarColumn(store: store)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
            TerminalWorkspace(
                artifact: artifact,
                showBrowser: $showBrowser,
                workspaceRoot: store.selectedWorkspaceRoot
            )
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if let room = store.selectedRoom {
                dockPane {
                    RoomDetailView(
                        room: room,
                        engine: store.engine,
                        readOnly: store.tab == .history
                    ) {
                        await store.load()
                    }
                    // Stable identity per room: composer draft survives the 5s
                    // refresh, resets when another room is selected.
                    .id(room.id)
                }
            } else if artifact.isOpen {
                dockPane { ArtifactPane(model: artifact) }
            }
        }
        .task { await store.load() }
        .onReceive(refresh) { _ in Task { await store.load() } }
        .onAppear {
            // --artifact opens the dock's artifact even when --room wins the
            // dock: the room shows in front, the artifact waits behind it.
            if let path = LaunchOptions.artifactPath {
                artifact.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }
        .enableInjection()
    }

    /// Shared chrome for the dock's two tenants: the sticky width and
    /// Esc-to-deselect. Esc lands here only while focus is inside the dock —
    /// the terminal rightly consumes its own Esc (TUIs live there), and the
    /// sidebar list carries its own onExitCommand. The artifact itself closes
    /// only via its ✕, never via Esc.
    private func dockPane(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(minWidth: 360, idealWidth: dockWidth, maxWidth: .infinity, maxHeight: .infinity)
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.width) { _, width in
                        dockWidth = width
                    }
                }
            )
            .onExitCommand { store.selection = nil }
    }
}

/// The center pane: tab strip over the selected terminal — the frame's
/// permanent tenant. (The artifact split that used to hang off this view now
/// lives in RootView's dock.)
struct TerminalWorkspace: View {
    @ObservedObject private var manager = TerminalManager.shared
    /// The dock's artifact model — the strip's browser popover opens files into it.
    @ObservedObject var artifact: ArtifactPaneModel
    @Binding var showBrowser: Bool
    /// Passed through to the strip's artifact browser — see `ArtifactBrowser`.
    let workspaceRoot: String?

    init(artifact: ArtifactPaneModel, showBrowser: Binding<Bool>, workspaceRoot: String?) {
        self.artifact = artifact
        _showBrowser = showBrowser
        self.workspaceRoot = workspaceRoot
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalStrip(
                manager: manager,
                artifact: artifact,
                showBrowser: $showBrowser,
                workspaceRoot: workspaceRoot
            )
            Divider()
            SessionPane(session: manager.selected)
        }
        // ⌘N — new terminal (HelmApp's key monitor posts these; see HelmApp.swift).
        .onReceive(NotificationCenter.default.publisher(for: .helmNewTerminal)) { _ in
            manager.newTerminal()
        }
        // ⌘1–⌘9 — select terminal by tab position.
        .onReceive(NotificationCenter.default.publisher(for: .helmSelectTerminal)) { note in
            if let index = note.object as? Int {
                manager.select(index: index)
            }
        }
        // ⌘O — the artifact browser popover (its "Browse…" rows reach the old
        // NSOpenPanel).
        .onReceive(NotificationCenter.default.publisher(for: .helmOpenArtifact)) { _ in
            showBrowser.toggle()
        }
        // ⌘+/⌘-/⌘0 — font zoom on the selected terminal. Ungated: the terminal
        // is always frontmost now (the old gate only silenced these while the
        // kild face covered the workspace).
        .onReceive(NotificationCenter.default.publisher(for: .helmAdjustFontSize)) { note in
            guard let raw = note.object as? Int,
                  let step = FontSizeStep(rawValue: raw)
            else { return }
            manager.selected.adjustFontSize(step)
        }
        // ⌘↑/⌘↓ — jump between shell prompts, gated on REAL terminal focus
        // (first responder), not mere visibility: the sidebar and dock hold
        // text fields where ⌘↑/↓ must keep its text-navigation meaning. The
        // key monitor applies the same gate before consuming the keystroke;
        // this guard covers the menu-item path.
        .onReceive(NotificationCenter.default.publisher(for: .helmJumpToPrompt)) { note in
            guard manager.selectedTerminalHasFocus, let offset = note.object as? Int else { return }
            manager.selected.jumpToPrompt(by: offset)
        }
    }
}

/// The selected session's surface (or its fallback when init failed / the shell
/// exited). Observes the session so status flips re-render just this pane.
private struct SessionPane: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Group {
            switch session.status {
            case .starting, .running:
                // .id ties the representable to this session: a tab switch
                // dismantles it (unmounting the old NSView) and mounts the new
                // session's view — never creating or destroying the views
                // themselves, so every pty survives.
                GhosttyHostView(view: session.hostView)
                    .id(session.id)
            case let .failed(message):
                fallback(title: "ghostty init failed", detail: message)
            case .exited:
                fallback(
                    title: "shell exited",
                    detail: "Close this tab, or open a new terminal with ⌘N."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func fallback(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding()
    }
}

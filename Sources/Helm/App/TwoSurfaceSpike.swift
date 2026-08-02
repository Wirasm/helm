import Inject
import SwiftUI

// MARK: - TwoSurfaceSpike

/// **THROWAWAY SPIKE — delete before Task 2.** Plan position 5, Phase 0, Task 1
/// (`~/.prp/helm-3ec376fc/plans/workbench-and-canvas-tail.plan.md`).
///
/// helm has **never** rendered two ghostty surfaces at once. Today exactly one is
/// mounted (`TerminalWorkspace.swift:21` mounts `manager.selected`); every other
/// session stays alive but unmounted, and #37's chat face deliberately keeps its
/// surface mounted underneath. The whole workbench rests on N-at-once being real,
/// so this answers it before any structural work starts.
///
/// Two questions, both driven from the bar at the top of this view:
///
/// 1. **Two surfaces at once.** Both grids draw; typing goes to whichever was
///    clicked; neither blanks when the other renders; closing one leaves the other
///    ticking. Answered by looking at the window and typing into each pane.
/// 2. **Zero attached surfaces.** *Detach all* swaps the split for a plain label,
///    so no `GhosttyHostView` is mounted and every surface has `window == nil` — a
///    state today's frame cannot reach, but a bench can (a slot showing a canvas
///    unmounts its terminal panes, and a workspace whose every slot shows a canvas
///    has nothing attached at all). Run the tick probe in both panes first, detach
///    past the interval, reattach, and see whether the shells made progress.
///
/// Gated on `--spike-two-surfaces` rather than replacing `RootView` outright, so
/// the same build runs normal helm too and the A/B costs no rebuild.
///
/// Deliberately **not** wired to `WorkspaceModel`: the spike never constructs one
/// and never calls `saveContext`, so it cannot write over the operator's
/// `helmWorkspaceContexts`. Both launch paths share the `com.wirasm.helm` domain
/// since #45, and a second helm that persisted would be racing the operator's live
/// instance for that key.
struct TwoSurfaceSpike: View {
    /// `--spike-two-surfaces` on the command line.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--spike-two-surfaces")
    }

    /// The probe for question 2: run it in BOTH panes, detach past 20s, reattach.
    /// A file that exists means the pty kept running with nothing attached.
    static let tickProbe = "sh -c 'sleep 20; date > /tmp/spike-tick-$$.txt'"

    @ObserveInjection private var inject
    /// `.shared`, not an isolated manager: `Keymap.install()` touches
    /// `TerminalManager.shared`, and a second manager would mean a second
    /// `ghostty_app_t`. Both sessions must sit on ONE controller — that is the
    /// configuration the vendored wakeup patch exists for and the one the bench
    /// will ship.
    @ObservedObject private var manager = TerminalManager.shared
    @State private var surfacesAttached = true

    /// The spike's own workspace, so it depends on no saved state.
    private var workspacePath: String { FileManager.default.currentDirectoryPath }

    private var panes: [TerminalSession] {
        Array(manager.sessions(for: workspacePath).prefix(2))
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if surfacesAttached {
                // `ForEach`, not two literal children: this is also the construct
                // Task 10 needs and the plan only has mechanism evidence for
                // (`_SplitViewContainer` takes `_VariadicView.Children`, the same
                // unpacking `HStack` uses). Two birds — if the split shows one
                // opaque pane instead of two, that is the ForEach question failing,
                // not the two-surface one.
                HSplitView {
                    ForEach(panes) { session in
                        pane(session)
                    }
                }
            } else {
                ContentUnavailableView(
                    "no surfaces attached", systemImage: "rectangle.slash",
                    description: Text(
                        "Every GhosttyHostView is unmounted, so every surface has "
                            + "window == nil. Wait past the probe's interval, then Reattach.")
                )
            }
        }
        .task {
            manager.activate(workspacePath: workspacePath)
            while manager.sessions(for: workspacePath).count < 2 {
                manager.newTerminal(in: workspacePath)
            }
        }
        .enableInjection()
    }

    /// One pane: a label naming the session so the two are tellable apart in a
    /// capture, over the surface itself.
    private func pane(_ session: TerminalSession) -> some View {
        VStack(spacing: 0) {
            SpikePaneLabel(session: session)
            Divider()
            GhosttyHostView(view: session.hostView).id(session.id)
        }
        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Text("TWO-SURFACE SPIKE").font(.caption.bold()).foregroundStyle(.orange)
            Text("\(panes.count) session(s) on 1 controller").font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Self.tickProbe).font(.caption.monospaced()).textSelection(.enabled)
                .foregroundStyle(.secondary)
            Button(surfacesAttached ? "Detach all surfaces" : "Reattach surfaces") {
                surfacesAttached.toggle()
            }
            Button("New session") { manager.newTerminal(in: workspacePath) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

// MARK: - SpikePaneLabel

/// Split out so a title or status change re-renders one pane's label rather than
/// the whole split — `@ObservedObject` on the session is what does that, the same
/// reason `TerminalStrip`'s tab holds one.
private struct SpikePaneLabel: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 6) {
            Circle().frame(width: 7, height: 7).foregroundStyle(color)
            Text(
                session.title.isEmpty ? "session \(session.id.uuidString.prefix(8))" : session.title
            )
            .font(.caption)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var color: Color {
        switch session.status {
        case .running: .green
        case .starting: .yellow
        case .failed, .exited: .red
        }
    }

    private var statusText: String {
        switch session.status {
        case .starting: "starting"
        case .running: "running"
        case .exited: "exited"
        case let .failed(message): "failed: \(message)"
        }
    }
}

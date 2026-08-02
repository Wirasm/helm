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
/// Three questions, all driven from the bar at the top of this view:
///
/// 1. **Two surfaces at once.** Both grids draw; typing goes to whichever was
///    clicked; neither blanks when the other renders; closing one leaves the other
///    ticking. **ANSWERED — passes** (operator-verified 2026-08-02).
/// 2. **Zero attached surfaces.** *Detach all* unmounts every host, so every
///    surface has `window == nil` — a state today's frame cannot reach, but a bench
///    can. **ANSWERED — passes**: a backgrounded pty ran a delayed command to
///    completion with nothing attached, and detach/reattach was verified live.
/// 3. **Moving a pane between containers.** *Move pane →* reparents a live session
///    from the left container's subtree to the right one's. The operator has made
///    this a requirement, so it is proven here rather than discovered in Phase 5.
///
/// Question 3's reasoning, and why the risk is the picture and not the process:
/// `TerminalManager` retains the session and the session retains its `hostView` for
/// the session's whole lifetime, and `GhosttyHostView` **mounts** that view rather
/// than constructing one — so a reparent deallocates nothing and the pty cannot die
/// with it. The lifecycle contract is about *lifetime*, not mount point
/// (`TerminalSession` header: "the surface is NOT destroyed on window detach …
/// only deallocating the view kills the pty"). What can still go wrong is the
/// drawing: cmux issue 7054 reports stable SwiftUI identity across a container move
/// **skipping the Metal surface reattach**, which keeps the shell and leaves a blank
/// pane. So the move is instrumented for the surface, not for the process.
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

    /// The probe for questions 2 and 3: start it in a pane, then detach or move
    /// past the interval. A file that exists afterwards means the pty kept running
    /// while its surface was unmounted or reparented.
    static let tickProbe = "sh -c 'sleep 45; date > /tmp/spike-move-done.txt'"

    /// `SPIKE_MOVE_AFTER=<seconds>`: fire the left→right move on a timer instead of
    /// on the button.
    ///
    /// Not a shortcut around the UI — it calls the same `movePaneRight()` the button
    /// does. It exists because the alternative for an agent is synthesising a click
    /// at a computed coordinate, and `AGENTS.md` records what that costs when the
    /// coordinate is stale: the click lands in whatever app is underneath. A timer
    /// makes the run deterministic and needs no pointer at all.
    ///
    /// An **environment variable, not a launch flag**, and that is measured rather
    /// than stylistic: launching with `--spike-move-after 75` in argv produced a
    /// process that ran its event loop happily but never created a window (0 windows
    /// via the accessibility API, no pty, `.task` never reached). `UserDefaults`
    /// folds every `-`-prefixed argv entry into `NSArgumentDomain`, so extra flags
    /// are not inert here the way `LaunchOptions`' header assumes. The env var cannot
    /// collide with that.
    static var moveAfter: TimeInterval? {
        ProcessInfo.processInfo.environment["SPIKE_MOVE_AFTER"].flatMap(Double.init)
    }

    @ObserveInjection private var inject
    /// `.shared`, not an isolated manager: `Keymap.install()` touches
    /// `TerminalManager.shared`, and a second manager would mean a second
    /// `ghostty_app_t`. Both sessions must sit on ONE controller — that is the
    /// configuration the vendored wakeup patch exists for and the one the bench
    /// will ship.
    @ObservedObject private var manager = TerminalManager.shared
    @State private var surfacesAttached = true

    /// Which container each session is in. Two arrays rather than one, because a
    /// move has to cross a real container boundary to mean anything: the moved
    /// pane's `GhosttyHostView` is dismantled from the left subtree and made in the
    /// right one, giving its `TerminalView` a different `superview` on the other
    /// side. Reordering inside a single `ForEach` would not exercise that at all.
    @State private var leftIDs: [TerminalSession.ID] = []
    @State private var rightIDs: [TerminalSession.ID] = []

    /// The spike's own workspace, so it depends on no saved state.
    private var workspacePath: String { FileManager.default.currentDirectoryPath }

    private var sessions: [TerminalSession] { manager.sessions(for: workspacePath) }

    private func session(_ id: TerminalSession.ID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if surfacesAttached {
                HSplitView {
                    container("left", ids: leftIDs)
                    container("right", ids: rightIDs)
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
            // Both start on the left so the first move is unambiguous: one pane
            // crosses, and the right container goes from empty to occupied.
            leftIDs = manager.sessions(for: workspacePath).map(\.id)
            rightIDs = []
            for session in manager.sessions(for: workspacePath) {
                SpikeDiagnostics.report("startup", session: session)
            }
            if let delay = Self.moveAfter {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    movePaneRight()
                }
            }
        }
        .enableInjection()
    }

    /// One container. A `VStack` per side, so the two sides are genuinely different
    /// subtrees rather than two positions in one.
    private func container(_ label: String, ids: [TerminalSession.ID]) -> some View {
        VStack(spacing: 0) {
            Text("container: \(label) — \(ids.count) pane(s)")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 3)
            Divider()
            if ids.isEmpty {
                Color.clear.overlay(Text("empty").font(.caption).foregroundStyle(.tertiary))
            } else {
                // `ForEach`, not literal children: this is also the construct Task 10
                // needs and the plan only has mechanism evidence for
                // (`_SplitViewContainer` takes `_VariadicView.Children`, the same
                // unpacking `HStack` uses).
                ForEach(ids, id: \.self) { id in
                    if let session = session(id) {
                        pane(session)
                    }
                }
            }
        }
        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One pane: a label naming the session so the two are tellable apart in a
    /// capture, over the surface itself.
    ///
    /// `.id(session.id)` is the stable pane identity the bench will use — and it is
    /// exactly the condition cmux 7054 blames for a skipped reattach, so the move
    /// must be tested with it present rather than with a churning id that would
    /// force a rebuild and hide the problem.
    private func pane(_ session: TerminalSession) -> some View {
        VStack(spacing: 0) {
            SpikePaneLabel(session: session)
            Divider()
            GhosttyHostView(view: session.hostView).id(session.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Text("SPIKE").font(.caption.bold()).foregroundStyle(.orange)
            Text("\(sessions.count) session(s) on 1 controller").font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Self.tickProbe).font(.caption.monospaced()).textSelection(.enabled)
                .foregroundStyle(.secondary)
            // ⌃⌘M / ⌃⌘B: a key equivalent rather than a click target, so the move can
            // be driven without synthesising a pointer event at a computed coordinate.
            Button("Move pane →") { movePaneRight() }
                .keyboardShortcut("m", modifiers: [.control, .command])
                .disabled(leftIDs.isEmpty)
            Button("← Move back") { movePaneLeft() }
                .keyboardShortcut("b", modifiers: [.control, .command])
                .disabled(rightIDs.isEmpty)
            Button(surfacesAttached ? "Detach all surfaces" : "Reattach surfaces") {
                surfacesAttached.toggle()
            }
            Button("New session") { manager.newTerminal(in: workspacePath) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: - The move

    private func movePaneRight() {
        guard let id = leftIDs.first else { return }
        move(
            id, from: { leftIDs.removeAll { $0 == id } }, to: { rightIDs.append(id) },
            direction: "left→right")
    }

    private func movePaneLeft() {
        guard let id = rightIDs.first else { return }
        move(
            id, from: { rightIDs.removeAll { $0 == id } }, to: { leftIDs.append(id) },
            direction: "right→left")
    }

    /// Reparent one pane and report the surface's state either side of it.
    ///
    /// Sampled *after* a main-queue hop, not inline: the mutation only marks the
    /// view dirty, and the reparent AppKit does in response has not happened yet
    /// when the button action returns. Reading `window`/`superview` inline would
    /// report the state before the thing being measured.
    private func move(
        _ id: TerminalSession.ID, from remove: () -> Void, to insert: () -> Void,
        direction: String
    ) {
        guard let session = session(id) else { return }
        SpikeDiagnostics.report("before \(direction)", session: session)
        remove()
        insert()
        DispatchQueue.main.async {
            SpikeDiagnostics.report("after  \(direction)", session: session)
        }
    }
}

// MARK: - SpikeDiagnostics

/// What the move has to be judged on, printed to stdout so it can be read from
/// outside the app — the whole point is a check that does not rest on someone
/// squinting at a screenshot.
///
/// `foregroundPid` is the process the pty is actually running, which is the
/// identity that must survive: if the reparent killed and respawned anything, this
/// changes. `window`/`superview`/`frame` are the surface side — a blank pane with a
/// live shell shows up here as `window=no`, a zero frame, or an unchanged superview
/// when the container did change.
@MainActor
enum SpikeDiagnostics {
    static func report(_ label: String, session: TerminalSession) {
        let view = session.hostView
        let pid = view.foregroundPid.map(String.init) ?? "none"
        let superview = view.superview.map { String(describing: type(of: $0)) } ?? "none"
        let size = view.frame.size
        print(
            "[spike-move] \(label) "
                + "session=\(session.id.uuidString.prefix(8)) "
                + "foregroundPid=\(pid) "
                + "window=\(view.window == nil ? "no" : "yes") "
                + "superview=\(superview) "
                + "frame=\(Int(size.width))x\(Int(size.height)) "
                + "status=\(session.status)")
        // Unbuffered: a spike whose evidence is still sitting in stdio's buffer
        // when the process is killed has measured nothing.
        fflush(stdout)
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
            Text("fg pid \(session.hostView.foregroundPid.map(String.init) ?? "—")")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
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

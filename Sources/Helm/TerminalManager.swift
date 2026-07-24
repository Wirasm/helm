import AppKit
import GhosttyTerminal
import SwiftUI

// MARK: - TerminalSession

/// One terminal session: its own ghostty runtime (`TerminalController`) plus the
/// single long-lived `AppTerminalView` whose coordinator owns the surface + pty.
///
/// Lifecycle contract (the load-bearing part, see docs/SPIKE.md): the surface is
/// owned by the NSView's coordinator and is NOT destroyed on window detach —
/// `viewDidMoveToWindow(nil)` only pauses rendering, and reattach reuses the
/// existing surface. Only deallocating the view kills the pty. `TerminalManager`
/// retains every session (and each session its view) for as long as the tab
/// exists, so the shell survives any SwiftUI unmount/remount — tab switches,
/// the ⌘T face toggle, artifact-pane resizes, all of it.
///
/// Why one controller PER session instead of one shared controller with N
/// surfaces: the C API would allow the latter (Ghostty.app itself is one
/// ghostty_app_t with many surfaces, and the wrapper's `createSurface` retains
/// a bridge per surface), but the Swift wrapper is not safe for it — each
/// view's `TerminalSurfaceCoordinator` claims `controller.onWakeup` /
/// `shouldProcessWakeup` as SINGLE slots on (re)build and nils them on
/// teardown (`TerminalSurfaceCoordinator.swift`: `rebuildIfReady` /
/// `tearDownSurface`). Shared, the last-built surface would steal app wakeups
/// and closing any tab would stall ticking for the survivors; the slots are
/// `internal`, so we can't re-own them. One controller ↔ one view is the
/// wrapper's tested pattern (its own test suite spins up multiple controllers
/// per process; `ghostty_init` is once-guarded internally).
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum Status: Equatable {
        /// Controller is up; surface spawns on first attach to a window with real size.
        case starting
        /// Surface attached — the shell is running.
        case running
        /// The shell process ended (exit / ⌃D).
        case exited
        /// Ghostty config/app init failed; the placeholder pane shows this.
        case failed(String)
    }

    let id = UUID()

    /// 1-based creation ordinal, monotonically assigned by the manager —
    /// the "shell N" fallback title when the shell hasn't set one.
    let ordinal: Int

    @Published private(set) var status: Status = .starting
    /// Terminal title (OSC 0/2 from the shell).
    @Published private(set) var title: String = ""

    /// Tab-strip label: the shell-reported title, or "shell N" until one arrives.
    var displayTitle: String {
        title.isEmpty ? "shell \(ordinal)" : title
    }

    /// The long-lived ghostty NSView (Metal-rendered; keyboard/IME/mouse/resize
    /// handled inside the wrapper). Host it via `GhosttyHostView` — never let
    /// SwiftUI own its lifetime.
    let hostView: TerminalView

    private let controller: TerminalController

    init(ordinal: Int) {
        self.ordinal = ordinal
        controller = Self.makeController()

        let view = TerminalView(frame: .zero)
        view.controller = controller
        // .exec = libghostty's real-pty backend. `command` is deliberately left
        // unset: libghostty then runs the user's passwd shell ($SHELL) as a
        // login shell — exactly the default-terminal behavior we want.
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        hostView = view

        view.delegate = self
        if let issue = controller.lastConfigurationIssue {
            status = .failed(issue)
        }
    }

    /// Ghostty config for helm. Factored out so the non-GUI smoke test can
    /// exercise ghostty_init + config load + app create without a window.
    static func makeController() -> TerminalController {
        TerminalController { builder in
            // The prebuilt xcframework ships headers + static lib only — no
            // terminfo. Ghostty's default TERM=xterm-ghostty breaks TUIs on
            // machines without Ghostty.app's terminfo installed, so pin the
            // universally available entry.
            builder.withCustom("term", "xterm-256color")
        }
    }

    var configIssue: String? {
        controller.lastConfigurationIssue
    }
}

// The wrapper reports surface events through fine-grained delegate protocols;
// we sink the ones helm needs into published state.
extension TerminalSession: TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceTitleDelegate
{
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        if status == .starting { status = .running }
    }

    func terminalDidDetachSurface() {
        // View detach without close — surface teardown is either dealloc (only
        // when the tab closes) or a rebuild; nothing to publish.
    }

    func terminalDidClose(processAlive _: Bool) {
        status = .exited
    }

    func terminalDidChangeTitle(_ title: String) {
        self.title = title
    }
}

// MARK: - TerminalManager

/// App-level owner of the ordered terminal sessions and the tab selection.
///
/// Invariants:
/// - `sessions` is never empty: init creates the first shell and `close`
///   refuses to remove the last one (the tab strip disables that button too).
/// - `selectedID` always names a live session; closing the selected tab moves
///   selection to its nearest surviving neighbor.
/// - Sessions (and their NSViews + ptys) live exactly as long as their tab:
///   dropping the last reference here deallocs the view → coordinator →
///   surface, which is what actually kills the shell.
@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    @Published private(set) var sessions: [TerminalSession]
    @Published private(set) var selectedID: TerminalSession.ID

    private var nextOrdinal = 1

    /// Internal (not private) so tests can build isolated managers; the app
    /// itself only ever uses `.shared`.
    init() {
        let first = TerminalSession(ordinal: nextOrdinal)
        nextOrdinal += 1
        sessions = [first]
        selectedID = first.id
    }

    var selected: TerminalSession {
        // `sessions` is never empty (see invariants), so the fallback only
        // covers a transient mid-update read.
        sessions.first { $0.id == selectedID } ?? sessions[0]
    }

    /// The last terminal cannot be closed — the tab strip disables its ✕.
    var canClose: Bool {
        sessions.count > 1
    }

    /// ⌘N / the strip's + button: a fresh login shell, appended and selected.
    func newTerminal() {
        let session = TerminalSession(ordinal: nextOrdinal)
        nextOrdinal += 1
        sessions.append(session)
        selectedID = session.id
    }

    func select(_ session: TerminalSession) {
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        selectedID = session.id
    }

    /// ⌘1–⌘9: select by 0-based tab position; out-of-range is a no-op.
    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedID = sessions[index].id
    }

    /// Closes the tab AND its shell: removing the session drops the last strong
    /// reference (once SwiftUI unmounts the view), deallocating view →
    /// coordinator → surface → pty. Refuses on the last remaining terminal.
    func close(_ session: TerminalSession) {
        guard canClose,
              let index = sessions.firstIndex(where: { $0.id == session.id })
        else { return }
        sessions.remove(at: index)
        if selectedID == session.id {
            selectedID = sessions[min(index, sessions.count - 1)].id
        }
    }
}

// MARK: - GhosttyHostView

/// Thin SwiftUI host for a session-owned terminal NSView. Deliberately does not
/// create the view: it mounts/unmounts the session's instance, so dismantling
/// the representable never tears down the surface or its pty. Callers must set
/// `.id(session.id)` next to it so a tab switch dismantles this representable
/// and makes a fresh one for the other session's view (an NSViewRepresentable
/// can never swap its NSView instance in place).
struct GhosttyHostView: NSViewRepresentable {
    let view: TerminalView
    /// Whether this pane is visible and should own focus. Drives first responder
    /// and render occlusion; the pty runs regardless.
    let isActive: Bool

    func makeNSView(context _: Context) -> TerminalView {
        view
    }

    func updateNSView(_ view: TerminalView, context _: Context) {
        view.setSurfaceVisible(isActive)
        // Focus follows visibility. Deferred: during a SwiftUI update the view
        // may not be in a window yet, and makeFirstResponder mid-update is unsafe.
        DispatchQueue.main.async { [isActive] in
            guard let window = view.window else { return }
            if isActive {
                if window.firstResponder !== view { window.makeFirstResponder(view) }
            } else if window.firstResponder === view {
                window.makeFirstResponder(nil)
            }
        }
    }
}

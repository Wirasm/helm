import AppKit
import GhosttyTerminal
import SwiftUI

/// App-level owner of the embedded ghostty terminal: the ghostty runtime/config
/// (`TerminalController`), and the single long-lived `AppTerminalView` whose
/// coordinator owns the surface + pty.
///
/// Lifecycle contract (the load-bearing part, see docs/SPIKE.md): the surface is
/// owned by the NSView's coordinator and is NOT destroyed on window detach —
/// `viewDidMoveToWindow(nil)` only pauses rendering, and reattach reuses the
/// existing surface. Only deallocating the view kills the pty. This singleton
/// retains the view for the process lifetime, so the shell session survives any
/// SwiftUI unmount/remount, not just the opacity toggle RootView happens to use.
@MainActor
final class GhosttyTerminal: ObservableObject {
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

    static let shared = GhosttyTerminal()

    @Published private(set) var status: Status = .starting
    /// Terminal title (OSC 0/2 from the shell).
    @Published private(set) var title: String = ""

    /// The long-lived ghostty NSView (Metal-rendered; keyboard/IME/mouse/resize
    /// handled inside the wrapper). Host it via `GhosttyHostView` — never let
    /// SwiftUI own its lifetime.
    let hostView: TerminalView

    private let controller: TerminalController

    private init() {
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
// we sink the ones the spike needs into published state.
extension GhosttyTerminal: TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceTitleDelegate
{
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        if status == .starting { status = .running }
    }

    func terminalDidDetachSurface() {
        // View detach without close — surface teardown is either dealloc (never,
        // we retain) or a rebuild; nothing to publish.
    }

    func terminalDidClose(processAlive _: Bool) {
        status = .exited
    }

    func terminalDidChangeTitle(_ title: String) {
        self.title = title
    }
}

/// Thin SwiftUI host for the app-owned terminal NSView. Deliberately does not
/// create the view: it mounts/unmounts the shared instance, so dismantling the
/// representable never tears down the surface or its pty.
struct GhosttyHostView: NSViewRepresentable {
    let view: TerminalView
    /// Whether this pane is the frontmost face of RootView. Drives focus and
    /// render occlusion; the pty runs regardless.
    let isActive: Bool

    func makeNSView(context _: Context) -> TerminalView {
        view
    }

    func updateNSView(_ view: TerminalView, context _: Context) {
        view.setSurfaceVisible(isActive)
        // Focus follows the toggle. Deferred: during a SwiftUI update the view
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

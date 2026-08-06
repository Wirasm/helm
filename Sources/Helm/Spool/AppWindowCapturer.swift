import AppKit
import HelmWire

/// The capture's edge: picks which of helm's windows to draw, and hands it to `WindowCapture`.
///
/// It lives in the spool's own slice rather than in `Capture/` for the same reason
/// `WorkbenchSpoolSpawner` does — it is the spool's adapter onto a window, not a capture
/// feature. The drawing itself is in `Capture/WindowCapture.swift`, where nothing knows a spool
/// exists.
///
/// **The window list comes in through a closure**, so "there are no windows" and "there are two
/// and neither is key" are both reachable from `swift test` without an `NSApplication`. Those
/// are the refusal paths, and they are exactly the ones a live run never hits by accident.
@MainActor
final class AppWindowCapturer: SpoolCapturing {
    private let windows: @MainActor () -> [NSWindow]
    private let keyWindow: @MainActor () -> NSWindow?
    /// helm's own terminal panes, so the report can say whether their cells are in the image.
    /// **Asked of the manager rather than found in the view tree**: once ghostty swaps a surface
    /// to an IOSurface-backed layer there is nothing in the tree to recognise it by, and a scan
    /// reported "no terminal in this window" about a capture full of terminal text.
    private let terminals: @MainActor () -> [NSView]

    init(
        windows: @escaping @MainActor () -> [NSWindow] = { NSApp?.windows ?? [] },
        keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow ?? NSApp?.mainWindow },
        terminals: @escaping @MainActor () -> [NSView] = {
            TerminalManager.shared.sessions.map(\.hostView)
        }
    ) {
        self.windows = windows
        self.keyWindow = keyWindow
        self.terminals = terminals
    }

    func capture(to path: String, window request: String?) -> Result<CaptureReport, SpoolRefusal> {
        let all = windows()
        switch Self.target(in: all, key: keyWindow(), named: request) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let window):
            guard let view = window.contentView else {
                return .failure(
                    SpoolRefusal("the window \"\(window.title)\" has no content view to draw"))
            }
            return WindowCapture.png(
                of: view, terminals: terminals(), window: window.title,
                appearance: .resolving(window.effectiveAppearance),
                to: URL(fileURLWithPath: path))
        }
    }

    /// Which window a capture means.
    ///
    /// **Ambiguity is refused, never guessed.** Two helms is the *normal* state while building
    /// helm, and one of them is the operator's live session — so a capturer that quietly picks
    /// the wrong one hands back a plausible image of somebody else's work, which is the
    /// silent-wrong-answer shape this codebase keeps removing. `winshot` has this failure by
    /// construction (it matches owner names by substring, `AGENTS.md`); this does not, because
    /// helm is inside the process and can name every candidate in the refusal.
    ///
    /// A key window settles it when helm is frontmost. When it is not — over ssh, on another
    /// Space, screen locked — there is no key window at all, and a single visible window is
    /// still unambiguous. Beyond that the caller has to say which.
    static func target(
        in windows: [NSWindow], key: NSWindow?, named request: String?
    ) -> Result<NSWindow, SpoolRefusal> {
        var candidates = windows.filter { $0.isVisible && $0.contentView != nil }
        guard !candidates.isEmpty else {
            return .failure(
                SpoolRefusal(
                    "helm has no visible window to draw (\(windows.count) window(s) exist, none "
                        + "of them visible with a content view — miniaturised or ordered out)."))
        }
        if let request {
            candidates = candidates.filter {
                $0.title.range(of: request, options: .caseInsensitive) != nil
            }
            guard !candidates.isEmpty else {
                return .failure(
                    SpoolRefusal(
                        "no visible helm window's title contains \"\(request)\". Titles: "
                            + Self.titles(windows.filter { $0.isVisible })))
            }
            guard candidates.count == 1 else {
                return .failure(
                    SpoolRefusal(
                        "\"\(request)\" matches \(candidates.count) windows: "
                            + Self.titles(candidates) + ". Name one of them exactly."))
            }
            return .success(candidates[0])
        }
        if let key, candidates.contains(where: { $0 === key }) { return .success(key) }
        guard candidates.count == 1 else {
            return .failure(
                SpoolRefusal(
                    "helm has \(candidates.count) visible windows and none of them is key, so "
                        + "which one to draw is the caller's to say. Pass \"window\" matching "
                        + "one of: " + Self.titles(candidates)))
        }
        return .success(candidates[0])
    }

    private static func titles(_ windows: [NSWindow]) -> String {
        windows.map { "\"\($0.title)\"" }.joined(separator: ", ")
    }
}

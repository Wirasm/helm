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
/// dock open/close, sidebar and artifact resizes, all of it.
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
    /// An inactive tab's shell rang the bell (BEL) — the tab strip shows a dot
    /// until the tab is selected. Bells on the visible tab are not marked.
    @Published private(set) var hasBell = false
    /// Command-activity chrome: live OSC 9;4 progress plus the
    /// finished-command tick/mark for inactive tabs (rules and formatting in
    /// TerminalCapabilities.swift). The strip renders it; selection
    /// acknowledges the outcome mark, bell keeps display precedence.
    @Published private(set) var activity = TerminalActivity()

    /// Set by TerminalManager so bell events can check the live selection.
    weak var manager: TerminalManager?

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
    ///
    /// Precedence (full story in GhosttyConfig.swift): the user's own Ghostty
    /// config is the base when one exists and validates, helm's required
    /// overrides land after it; otherwise helm's defaults apply.
    static func makeController() -> TerminalController {
        GhosttyResources.installIfAvailable()
        return makeController(userConfig: validatedUserConfig)
    }

    static func makeController(userConfig: String?) -> TerminalController {
        if let userConfig {
            // User config as the base; only the required overrides after it.
            // Theme stays empty so the user's colors (incl. `theme =
            // light:…,dark:…`, which ghostty itself re-resolves on
            // setColorScheme) are never stomped by helm's.
            return TerminalController(
                configSource: .generated(userConfig),
                theme: TerminalTheme(),
                terminalConfiguration: requiredOverrides
            )
        }
        return TerminalController(
            configSource: .generated(defaultConfiguration.rendered),
            theme: defaultTheme,
            terminalConfiguration: requiredOverrides
        )
    }

    /// Overrides helm applies AFTER any base config (ghostty's last-value-wins
    /// rule). `term`: the embedded xcframework ships no terminfo, so ghostty's
    /// default TERM=xterm-ghostty breaks TUIs on machines without Ghostty.app's
    /// terminfo installed (and over ssh regardless) — pin the universal entry.
    static let requiredOverrides = TerminalConfiguration { builder in
        builder.withCustom("term", "xterm-256color")
    }

    /// Helm's own defaults, used only when the user has no Ghostty config:
    /// 13pt mono with a taller cell for breathing room, modest padding, and
    /// scrollback sized for agent transcripts (bytes, allocated lazily by
    /// ghostty). Font family is left unset on purpose — libghostty falls back
    /// to its embedded JetBrains Mono, which beats anything named blindly.
    static let defaultConfiguration = TerminalConfiguration { builder in
        builder.withFontSize(13)
        builder.withFontThicken(true)
        builder.withCursorStyle(.block)
        builder.withCursorStyleBlink(true)
        builder.withCustom("adjust-cell-height", "15%")
        builder.withWindowPaddingX(8)
        builder.withWindowPaddingY(4)
        builder.withCustom("scrollback-limit", "104857600") // 100 MiB
    }

    /// Light/dark colors following helm's appearance override — the wrapper's
    /// NSView observes effectiveAppearance and re-resolves the theme itself,
    /// so NSApp.appearance changes re-theme live terminals with no helm code.
    static let defaultTheme = TerminalTheme(
        light: TerminalConfiguration { builder in
            builder.withBackground("#ffffff")
            builder.withForeground("#1f2328")
            // Raw string, not withMinimumContrast: the wrapper renders Double
            // values via a locale-sensitive formatter, which produces "1,2"
            // under comma-decimal locales — a hard ghostty config error.
            builder.withCustom("minimum-contrast", "1.2")
        },
        dark: TerminalConfiguration { builder in
            builder.withBackground("#22262c")
            builder.withForeground("#e8eaed")
        }
    )

    /// The user's Ghostty config, loaded and validated once per process.
    /// Validation matters because the wrapper hard-rejects any config with
    /// diagnostics (e.g. `theme = <name>` with no resources dir to resolve
    /// it) — a rejected config is dropped whole, with a logged warning and
    /// helm defaults instead: a terminal that opens beats a faithfully
    /// broken one.
    static let validatedUserConfig: String? = {
        guard let contents = GhosttyUserConfig.load() else { return nil }
        guard validateUserConfig(contents) else {
            NSLog("helm: user ghostty config rejected by ghostty — using helm defaults instead")
            return nil
        }
        return contents
    }()

    /// Probe-loads a config through a throwaway controller. Empty theme +
    /// empty overrides make the probe strict: any diagnostic stays visible in
    /// `lastConfigurationIssue` instead of being cleared by a later
    /// successful re-render (which the wrapper does whenever overrides or a
    /// theme are layered on).
    static func validateUserConfig(_ contents: String) -> Bool {
        let probe = TerminalController(
            configSource: .generated(contents),
            theme: TerminalTheme(),
            terminalConfiguration: TerminalConfiguration()
        )
        return probe.lastConfigurationIssue == nil
    }

    var configIssue: String? {
        controller.lastConfigurationIssue
    }

    /// ⌘+/⌘-/⌘0 on the selected terminal. Uses ghostty's own binding actions
    /// (`increase_font_size:1`, …) on the live surface — a true runtime
    /// change: the grid reflows in place, no config reload, the pty is
    /// untouched. Per-surface, so each tab keeps its own zoom. No-op until
    /// the surface exists (before first attach / after exit).
    func adjustFontSize(_ step: FontSizeStep) {
        switch step {
        case .increase: hostView.performBindingAction("increase_font_size:1")
        case .decrease: hostView.performBindingAction("decrease_font_size:1")
        case .reset: hostView.performBindingAction("reset_font_size")
        }
    }

    /// ⌘↑/⌘↓ — ghostty's `jump_to_prompt` scroll on the live surface
    /// (negative = older prompts). Only moves where shell integration has
    /// left OSC 133 prompt marks; in agent sessions each turn's prompt is a
    /// mark, so this is jump-between-turns. No-op without a surface.
    func jumpToPrompt(by offset: Int) {
        hostView.jumpToPrompt(by: Int16(clamping: offset))
    }

    /// Called by the manager when this session becomes selected: looking at
    /// a terminal acknowledges its bell and its finished-command mark.
    func acknowledgeAttention() {
        if hasBell { hasBell = false }
        if activity.outcome != nil { activity.acknowledge() }
    }
}

/// Direction of a per-terminal font zoom (⌘+ / ⌘- / ⌘0). The notification
/// carries the raw value, mirroring how ⌘1–⌘9 carry the tab index.
enum FontSizeStep: Int {
    case decrease = -1
    case reset = 0
    case increase = 1
}

// The wrapper reports surface events through fine-grained delegate protocols;
// we sink the ones helm needs into published state.
extension TerminalSession: TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceHoverLinkDelegate,
    TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceDesktopNotificationDelegate
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

    func terminalDidRingBell() {
        // Only inactive tabs get marked — a bell on the tab the user is
        // looking at needs no indicator (and would linger stale otherwise).
        guard manager?.selectedID != id else { return }
        hasBell = true
    }

    /// ⌘-click on a link in the grid. The allowlist (TerminalURLPolicy) is
    /// the whole security story: terminal content is untrusted, so anything
    /// but http/https/file/mailto is dropped silently.
    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        guard let validated = TerminalURLPolicy.validated(url) else { return }
        NSWorkspace.shared.open(validated)
    }

    /// Hover feedback for ⌘-clickable links: ghostty renders the underline
    /// itself; helm adds the destination as the view's tooltip so the user
    /// can see where a ⌘-click would go. nil = hover ended.
    func terminalDidUpdateHoverLink(_ url: String?) {
        hostView.toolTip = url
    }

    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        activity.reportProgress(state: state, percent: percent)
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        activity.finishCommand(
            exitCode: exitCode,
            durationNanos: durationNanos,
            isSelected: manager?.selectedID == id
        )
    }

    /// OSC 9 / OSC 777 desktop notification. Delivered only when helm is in
    /// the background or the tab is unselected; title is the tab's, body is
    /// the message (OSC 9 carries only a body — fall back to the sequence's
    /// title so neither form delivers an empty banner).
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        guard TerminalNotificationGate.shouldDeliver(
            appIsActive: NSApp.isActive,
            tabIsSelected: manager?.selectedID == id
        ) else { return }
        let message = body.isEmpty ? title : body
        guard !message.isEmpty else { return }
        TerminalNotifier.shared.deliver(title: displayTitle, body: message)
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
        first.manager = self
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

    /// Whether the selected terminal's view is (or contains) the key window's
    /// first responder — the focus gate for terminal-only shortcuts (⌘↑/⌘↓
    /// prompt jump). Needed since the one-surface re-layout: the terminal is
    /// always frontmost now, so "the terminal face is active" no longer
    /// implies the terminal has keyboard focus.
    var selectedTerminalHasFocus: Bool {
        let view = selected.hostView
        guard let window = view.window, window.isKeyWindow,
              let responder = window.firstResponder as? NSView
        else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// ⌘N / the strip's + button: a fresh login shell, appended and selected.
    func newTerminal() {
        let session = TerminalSession(ordinal: nextOrdinal)
        nextOrdinal += 1
        session.manager = self
        sessions.append(session)
        setSelected(session)
    }

    func select(_ session: TerminalSession) {
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        setSelected(session)
    }

    /// ⌘1–⌘9: select by 0-based tab position; out-of-range is a no-op.
    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        setSelected(sessions[index])
    }

    /// Selection always clears the incoming tab's bell and finished-command
    /// marks — looking at a terminal acknowledges its attention state.
    private func setSelected(_ session: TerminalSession) {
        selectedID = session.id
        session.acknowledgeAttention()
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
            setSelected(sessions[min(index, sessions.count - 1)])
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

    func makeNSView(context _: Context) -> TerminalView {
        view
    }

    func updateNSView(_ view: TerminalView, context _: Context) {
        // Always visible: the terminal is the frame's permanent center now
        // (the old kild face that occluded it is gone).
        view.setSurfaceVisible(true)
        // Focus, deferred: during a SwiftUI update the view may not be in a
        // window yet, and makeFirstResponder mid-update is unsafe. The claim
        // is deliberately NON-stealing — only when nothing else holds focus
        // (responder == window). updateNSView re-runs on every poll-driven
        // re-render, and grabbing focus each tick would make the sidebar and
        // the dock composer untypable. AppKit hands the first responder back
        // to the window when a focused view unmounts (tab switch, dock
        // close), so the terminal reclaims focus exactly then.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if window.firstResponder === window {
                window.makeFirstResponder(view)
            }
        }
    }
}

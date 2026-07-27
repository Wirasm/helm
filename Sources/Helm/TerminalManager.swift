import AppKit
import GhosttyTerminal
import SwiftUI

// MARK: - TerminalSession

/// One terminal session: a surface on the manager's shared ghostty runtime,
/// plus the single long-lived `AppTerminalView` whose coordinator owns that
/// surface + its pty.
///
/// Lifecycle contract (the load-bearing part, see docs/SPIKE.md): the surface is
/// owned by the NSView's coordinator and is NOT destroyed on window detach —
/// `viewDidMoveToWindow(nil)` only pauses rendering, and reattach reuses the
/// existing surface. Only deallocating the view kills the pty. `TerminalManager`
/// retains every session (and each session its view) for as long as the tab
/// exists, so the shell survives any SwiftUI unmount/remount — tab switches,
/// dock open/close, sidebar and artifact resizes, all of it.
///
/// Why the controller is INJECTED, never built here: one `TerminalController`
/// is one `ghostty_app_t`, and Ghostty.app itself runs a single app runtime
/// with many surfaces. Every tab carrying its own runtime made cost scale with
/// tab count for nothing, so `TerminalManager` creates exactly one controller
/// and hands the same instance to every session. Setting `view.controller`
/// then makes the view's coordinator create a surface on the SHARED app.
///
/// This only became safe with the vendored wrapper's wakeup patch
/// (Patches/libghostty-spm-multi-surface-wakeup.patch, docs/VENDORED.md).
/// Upstream 1.3.1 held `onWakeup` / `shouldProcessWakeup` as single slots that
/// each coordinator claimed on (re)build and nil'd on teardown, so a second
/// surface stole app wakeups from the first and closing any tab stalled every
/// survivor — both defects reproduced in the fork's test suite before the fix.
/// The patch turns those slots into a registry keyed on callback-bridge
/// identity: each coordinator subscribes on build, drops only its own entry on
/// teardown, and `handleWakeup` ticks the app once and fans out. Do NOT revert
/// to one controller per session without also reverting that pin.
///
/// One side effect worth knowing: `ghostty_app_tick` is app-wide, so any
/// single attached surface now drives the runtime for every surface on it,
/// including the ones SwiftUI has unmounted.
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
    /// The workspace that groups this session in the frame. The manager remains
    /// the owner of every session and the one shared ghostty controller.
    let workspacePath: String

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

    /// The manager's shared ghostty runtime. Internal rather than private so
    /// tests can assert every session holds the same instance.
    let controller: TerminalController

    init(ordinal: Int, workspacePath: String, controller: TerminalController) {
        self.ordinal = ordinal
        self.workspacePath = workspacePath
        self.controller = controller

        let view = TerminalView(frame: .zero)
        view.controller = controller
        // .exec = libghostty's real-pty backend. `command` is deliberately left
        // unset: libghostty then runs the user's passwd shell ($SHELL) as a
        // login shell — exactly the default-terminal behavior we want.
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workspacePath
        )
        hostView = view

        view.delegate = self
        // A config failure is global now, not per-tab: the controller is
        // shared, so every session reports the same issue and every pane shows
        // the same placeholder. That is correct — the config IS the app's —
        // but it means one bad key fails all tabs at once, not just the next
        // one opened.
        if let issue = controller.lastConfigurationIssue {
            status = .failed(issue)
        }
    }

    /// Ghostty config for helm. Factored out so the non-GUI smoke test can
    /// exercise ghostty_init + config load + app create without a window.
    ///
    /// Precedence (full story in GhosttyConfig.swift): helm's defaults are the
    /// BASE, the user's own Ghostty config layers on top of them, and helm's
    /// session overrides land last. Having a Ghostty config therefore changes
    /// only the keys it actually mentions — it no longer discards helm's tuning
    /// wholesale, which is how a one-line keybind file used to cost a user the
    /// cell height, padding and scrollback.
    static func makeController() -> TerminalController {
        GhosttyResources.installIfAvailable()
        return makeController(userConfig: validatedUserConfig)
    }

    static func makeController(userConfig: String?) -> TerminalController {
        guard let userConfig else {
            return TerminalController(
                configSource: .generated(defaultConfiguration.rendered),
                theme: defaultTheme,
                terminalConfiguration: sessionOverrides
            )
        }
        // Helm's defaults first, the user's config after them: ghostty's
        // last-value-wins rule makes every key they set win, and leaves the
        // rest of helm's tuning standing.
        //
        // Theme stays empty whenever a user config exists, so their colors
        // (incl. `theme = light:…,dark:…`, which ghostty re-resolves on
        // setColorScheme) are never stomped by helm's — the theme is applied
        // through a separate channel that would otherwise always win.
        return TerminalController(
            configSource: .generated(defaultConfiguration.rendered + "\n" + userConfig),
            theme: TerminalTheme(),
            terminalConfiguration: sessionOverrides
        )
    }

    /// What helm applies AFTER any base config (ghostty's last-value-wins
    /// rule) — the two things helm must win, plus the one thing the human set
    /// inside helm:
    ///
    /// - `term`: the embedded xcframework ships no terminfo, so ghostty's
    ///   default TERM=xterm-ghostty breaks TUIs on machines without
    ///   Ghostty.app's terminfo installed (and over ssh regardless).
    /// - `scrollback-limit`: not taste but a job requirement — an agent
    ///   transcript outruns a general-purpose terminal's default in minutes,
    ///   and a Ghostty config tuned for shell work has no reason to know that.
    /// - `font-size`: only once ⌘+/⌘- has been used. A size chosen inside helm
    ///   is a more direct statement of intent than a config written months ago,
    ///   so it outranks even the user config.
    static var sessionOverrides: TerminalConfiguration {
        let chosenFontSize = persistedFontSize
        return TerminalConfiguration { builder in
            builder.withCustom("term", "xterm-256color")
            builder.withCustom("scrollback-limit", "104857600") // 100 MiB
            if let chosenFontSize { builder.withFontSize(chosenFontSize) }
        }
    }

    /// Helm's baseline font size — the size helm's first ⌘+ steps up from when
    /// the user's config declares none of its own.
    static let baseFontSize: Float = 13

    /// Helm's own defaults: the BASE every terminal starts from, whether or not
    /// the user has a Ghostty config. A taller cell for breathing room (agent
    /// output is read, not just watched scroll past), modest padding. Font
    /// family is left unset on purpose — libghostty falls back to its embedded
    /// JetBrains Mono, which beats anything named blindly.
    static let defaultConfiguration = TerminalConfiguration { builder in
        builder.withFontSize(baseFontSize)
        builder.withFontThicken(true)
        builder.withCursorStyle(.block)
        builder.withCursorStyleBlink(true)
        builder.withCustom("adjust-cell-height", "15%")
        builder.withWindowPaddingX(8)
        builder.withWindowPaddingY(4)
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

    // MARK: - Font size

    private static let fontSizeDefaultsKey = "helmTerminalFontSize"

    /// The size the human picked with ⌘+/⌘-, or nil while they never have.
    /// Persisting it is the whole point: ghostty's zoom actions live on the
    /// surface, so without this every new tab and every relaunch silently
    /// dropped back to the config's size.
    static var persistedFontSize: Float? {
        get {
            guard UserDefaults.standard.object(forKey: fontSizeDefaultsKey) != nil else {
                return nil
            }
            return Float(UserDefaults.standard.double(forKey: fontSizeDefaultsKey))
        }
        set {
            guard let newValue else {
                return UserDefaults.standard.removeObject(forKey: fontSizeDefaultsKey)
            }
            UserDefaults.standard.set(Double(newValue), forKey: fontSizeDefaultsKey)
        }
    }

    /// The size a terminal opens at today: the human's choice, else whatever
    /// their own config declares, else helm's baseline. Stepping from the
    /// user's declared size matters — otherwise the first ⌘+ would jump from
    /// their 16pt down to helm's 14.
    static var effectiveFontSize: Float {
        persistedFontSize ?? declaredUserFontSize ?? baseFontSize
    }

    /// `font-size` as declared by the user's own validated config, if at all.
    static let declaredUserFontSize: Float? = validatedUserConfig
        .flatMap(GhosttyUserConfig.declaredFontSize)

    /// ⌘+/⌘-/⌘0 on the selected terminal. Two effects: ghostty's own binding
    /// action reflows THIS surface in place (no config reload, pty untouched),
    /// and the resulting size is persisted so every terminal opened afterwards
    /// starts there. Already-open tabs keep the size they were created at —
    /// ⌘0 clears the preference, and returns this surface to its own baseline.
    /// No-op on the surface until it exists (before first attach / after exit).
    func adjustFontSize(_ step: FontSizeStep) {
        switch step {
        case .increase:
            Self.persistedFontSize = min(Self.effectiveFontSize + 1, 72)
            hostView.performBindingAction("increase_font_size:1")
        case .decrease:
            Self.persistedFontSize = max(Self.effectiveFontSize - 1, 4)
            hostView.performBindingAction("decrease_font_size:1")
        case .reset:
            Self.persistedFontSize = nil
            hostView.performBindingAction("reset_font_size")
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
/// - Every session shares this manager's ONE `TerminalController` — one
///   `ghostty_app_t` for the whole app, N surfaces on it (see the
///   TerminalSession header). It is owned here rather than globally so tests
///   can build isolated managers without leaking runtime state between them.
@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    /// Flat app-level ownership of every workspace's sessions. Switching a
    /// workspace only changes which subset is mounted; it never releases one.
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var selectedID: TerminalSession.ID?
    @Published private(set) var activeWorkspacePath: String?

    /// The single ghostty runtime every session's surface is created on.
    let controller: TerminalController

    private var nextOrdinal = 1

    /// Internal (not private) so tests can build isolated managers; the app
    /// itself only ever uses `.shared`.
    init() {
        controller = TerminalSession.makeController()
        // No pty is created until a workspace is first visited. This bounds
        // startup cost to the active context rather than all remembered folders.
    }

    func sessions(for workspacePath: String) -> [TerminalSession] {
        sessions.filter { $0.workspacePath == workspacePath }
    }

    /// Makes a workspace active and lazily gives it its first shell. Existing
    /// sessions are merely parked (their retained NSViews and ptys survive).
    func activate(workspacePath: String, selectedID preferredID: UUID? = nil) {
        activeWorkspacePath = workspacePath
        let workspaceSessions = sessions(for: workspacePath)
        if workspaceSessions.isEmpty {
            newTerminal(in: workspacePath)
        } else if let preferredID, workspaceSessions.contains(where: { $0.id == preferredID }),
                  let preferred = workspaceSessions.first(where: { $0.id == preferredID }) {
            setSelected(preferred)
        } else if let selectedID, workspaceSessions.contains(where: { $0.id == selectedID }) {
            // Keep this workspace's selection when returning to it.
        } else if let first = workspaceSessions.first {
            setSelected(first)
        }
    }

    func deactivate() {
        activeWorkspacePath = nil
        selectedID = nil
    }

    /// Closing a workspace is an explicit tab teardown, unlike switching: drop
    /// every session it owns so their retained NSViews release their ptys.
    func closeWorkspace(_ workspacePath: String) {
        sessions.removeAll { $0.workspacePath == workspacePath }
        if activeWorkspacePath == workspacePath { deactivate() }
    }

    var selected: TerminalSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    /// The last terminal in the active workspace cannot be closed.
    var canClose: Bool {
        guard let activeWorkspacePath else { return false }
        return sessions(for: activeWorkspacePath).count > 1
    }

    /// Whether the selected terminal's view is (or contains) the key window's
    /// first responder — the focus gate for terminal-only shortcuts (⌘↑/⌘↓
    /// prompt jump). Needed since the one-surface re-layout: the terminal is
    /// always frontmost now, so "the terminal face is active" no longer
    /// implies the terminal has keyboard focus.
    var selectedTerminalHasFocus: Bool {
        guard let selected else { return false }
        let view = selected.hostView
        guard let window = view.window, window.isKeyWindow,
              let responder = window.firstResponder as? NSView
        else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// ⌘N / the strip's + button: a fresh login shell in the active workspace.
    func newTerminal() {
        guard let activeWorkspacePath else { return }
        newTerminal(in: activeWorkspacePath)
    }

    func newTerminal(in workspacePath: String) {
        let session = TerminalSession(ordinal: nextOrdinal, workspacePath: workspacePath, controller: controller)
        nextOrdinal += 1
        session.manager = self
        sessions.append(session)
        activeWorkspacePath = workspacePath
        setSelected(session)
    }

    func select(_ session: TerminalSession) {
        guard session.workspacePath == activeWorkspacePath,
              sessions.contains(where: { $0.id == session.id }) else { return }
        setSelected(session)
    }

    /// ⌘1–⌘9: select by 0-based tab position; out-of-range is a no-op.
    func select(index: Int) {
        guard let activeWorkspacePath else { return }
        let workspaceSessions = sessions(for: activeWorkspacePath)
        guard workspaceSessions.indices.contains(index) else { return }
        setSelected(workspaceSessions[index])
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
        guard session.workspacePath == activeWorkspacePath,
              canClose,
              let index = sessions.firstIndex(where: { $0.id == session.id })
        else { return }
        let workspaceSessions = sessions(for: session.workspacePath)
        let workspaceIndex = workspaceSessions.firstIndex(where: { $0.id == session.id }) ?? 0
        sessions.remove(at: index)
        if selectedID == session.id {
            let survivors = sessions(for: session.workspacePath)
            setSelected(survivors[min(workspaceIndex, survivors.count - 1)])
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

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

    /// Injectable so a relaunch can rebuild a workspace's tab row under the ids
    /// it was persisted with — which is what keeps `selectedTerminalID` meaningful
    /// across restarts. Fresh terminals still mint their own.
    let id: UUID

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
    /// `TerminalActivity`). The strip renders it; selection
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

    init(
        id: UUID = UUID(), ordinal: Int, workspacePath: String, controller: TerminalController
    ) {
        self.id = id
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
            builder.withCustom("scrollback-limit", "104857600")  // 100 MiB
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
    static let declaredUserFontSize: Float? =
        validatedUserConfig
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

/// Where a ⌘-clicked link goes once `TerminalURLPolicy` has admitted it.
///
/// Pure and separate from the session for the same reason `TerminalURLPolicy` and
/// `TerminalNotificationGate` are: a delegate callback needs a live ghostty surface,
/// so it cannot be reached from `swift test`. Keeping the decision here leaves the
/// callback with nothing but the posting, and puts the routing under test.
/// Carries no URL: the destination is the whole decision, and the URL that goes
/// there is the one that was routed.
enum TerminalLinkRoute: Equatable {
    /// A file helm renders — the canvas opens it.
    case canvasFile
    /// A web address — the canvas follows it, instead of a browser taking the operator
    /// out of the app.
    case canvasURL
    /// Everything else the allowlist admits: `mailto:`, and files helm has no renderer
    /// for. The system still owns the apps that handle those.
    case system

    /// **Two policies, two jobs — composed, never merged.** `TerminalURLPolicy` is the
    /// outer gate on untrusted terminal content and has already run when we get here;
    /// `CanvasURLPolicy` answers the narrower question of whether the canvas will
    /// *follow* what the gate let through. `mailto:` passing the gate and being refused
    /// by the canvas is the wanted outcome, not a gap: helm has no mail client and
    /// should not pretend to.
    ///
    /// Asking `CanvasURLPolicy` rather than re-deriving http/https here is what keeps
    /// the terminal's idea of what the canvas takes from drifting away from the canvas's.
    static func route(_ url: URL) -> TerminalLinkRoute {
        if url.isFileURL {
            return RenderableFile.isRenderable(url) ? .canvasFile : .system
        }
        return CanvasURLPolicy.allows(url) ? .canvasURL : .system
    }
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
    ///
    /// This is also the agent→helm channel, and it used to point out of the app: every
    /// link went to `NSWorkspace`, so an agent offering a rendered report tabbed you
    /// into a browser — the trip helm exists to absorb. A link to something the
    /// canvas renders now opens **in helm** instead.
    ///
    /// **Offer, not push.** The agent writes a self-contained file or prints an
    /// address; helm opens it only when you ⌘-click. Nothing appears unbidden — it is
    /// not helm's job to rearrange the bench on the agent's word.
    ///
    /// Both things the canvas renders come in this way: a `.md`/`.html` file, and an
    /// http address — an agent's `http://localhost:3000` opens **in helm** rather than
    /// tabbing the operator into a browser. A closed canvas opens itself on either,
    /// because the canvas subscribes on its model rather than on a view.
    ///
    /// Everything else the allowlist admits — a PDF, an image, `mailto:` — keeps its
    /// old route to the system, which still owns the apps that handle them.
    /// `TerminalLinkRoute` makes that three-way choice; this method only posts it.
    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        guard let validated = TerminalURLPolicy.validated(url) else { return }
        switch TerminalLinkRoute.route(validated) {
        case .canvasFile:
            NotificationCenter.default.post(name: .helmOpenCanvasFile, object: validated)
        case .canvasURL:
            NotificationCenter.default.post(name: .helmOpenCanvasURL, object: validated)
        case .system:
            NSWorkspace.shared.open(validated)
        }
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
        guard
            TerminalNotificationGate.shouldDeliver(
                appIsActive: NSApp.isActive,
                tabIsSelected: manager?.selectedID == id
            )
        else { return }
        let message = body.isEmpty ? title : body
        guard !message.isEmpty else { return }
        TerminalNotifier.shared.deliver(title: displayTitle, body: message)
    }
}

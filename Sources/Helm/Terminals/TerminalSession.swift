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
    let workspacePath: WorkspacePath
    /// Bypassing the notification gate is safe only if a burst cannot flood it.
    private var refusalThrottle = RefusalThrottle()

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

    /// Whether the operator can see this terminal — pushed in by `WorkbenchModel`
    /// whenever the bench changes.
    ///
    /// **Pushed, not pulled, and "visible" rather than "selected".** Every rule below
    /// used to ask `manager?.selectedID == id`, which worked while there was exactly one
    /// mounted terminal per workspace. Under a bench several panes are their slot's
    /// selection *at the same time* and all of them are on screen, so "selected" stops
    /// having one answer per session — while "the operator can see this one", which is
    /// what the bell and notification rules always meant, still does.
    ///
    /// Becoming visible acknowledges the tab's attention marks, exactly as
    /// `TerminalManager.setSelected` did: looking at a terminal is what clears it.
    var isVisible = false {
        didSet {
            if isVisible, !oldValue { acknowledgeAttention() }
        }
    }

    /// The owner, for everything that is not selection. Nothing about visibility goes
    /// through it any more, which is what let `selectedID` be deleted outright.
    weak var manager: TerminalManager?

    /// Tab-strip label: the shell-reported title, or "shell N" until one arrives.
    var displayTitle: String {
        title.isEmpty ? "shell \(ordinal)" : title
    }

    /// The long-lived ghostty NSView (Metal-rendered; keyboard/IME/mouse/resize
    /// handled inside the wrapper). Host it via `GhosttyHostView` — never let
    /// SwiftUI own its lifetime.
    let hostView: FocusClaimingTerminalView

    /// The manager's shared ghostty runtime. Internal rather than private so
    /// tests can assert every session holds the same instance.
    let controller: TerminalController

    /// `backend` is `.exec` — libghostty's real-pty backend — everywhere but the keyboard
    /// tests. Those need the bytes a keystroke produces to be *readable*, and an exec
    /// surface writes them into a pty file descriptor nothing in-process can see, where an
    /// in-memory one hands them to a closure. It is the vendor's own seam
    /// (`TerminalSessionBackend`), not one invented here, and it is the only way to assert
    /// what #96 is about: that a synthesised keystroke actually reaches the shell.
    init(
        id: UUID = UUID(), ordinal: Int, workspacePath: WorkspacePath,
        controller: TerminalController,
        backend: TerminalSessionBackend = .exec
    ) {
        self.id = id
        self.ordinal = ordinal
        self.workspacePath = workspacePath
        self.controller = controller

        let view = FocusClaimingTerminalView(frame: .zero)
        view.controller = controller
        // .exec runs the user's passwd shell ($SHELL) as a login shell — `command` is
        // deliberately left unset, which is exactly the default-terminal behavior we want.
        //
        // The env carries this pane's own id (#94). It is set here, before the surface is
        // created on first attach, so the uuid is baked into the child at spawn and survives
        // everything that does not respawn it — a move between containers included.
        view.configuration = TerminalSurfaceOptions(
            backend: backend,
            workingDirectory: workspacePath.value,
            envVars: PaneEnvironment.forPane(id)
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

    /// Helm's defaults first, the user's config after them: ghostty's last-value-wins rule
    /// makes every key they set win, and leaves the rest of helm's tuning standing.
    ///
    /// **The theme is unconditional now, and that is the change.** It used to go empty the
    /// moment a user config existed, so that their colours were never stomped — which is
    /// also why a helm terminal looked like *their Ghostty* rather than like helm. The
    /// theme channel renders last and therefore wins, and helm wants it to: the colours are
    /// the one thing helm has to own for the app to read as one surface. Which keys that
    /// covers, and which stay the operator's, is written out in `GhosttyConfig.swift`.
    static func makeController(userConfig: String?) -> TerminalController {
        let base = [defaultConfiguration.rendered, userConfig]
            .compactMap { $0 }
            .joined(separator: "\n")
        return TerminalController(
            configSource: .generated(base),
            theme: terminalTheme,
            terminalConfiguration: sessionOverrides
        )
    }

    /// What helm applies AFTER any base config (ghostty's last-value-wins
    /// rule) — the things helm must win, plus the one thing the human set
    /// inside helm:
    ///
    /// - `term`: the embedded xcframework ships no terminfo, so ghostty's
    ///   default TERM=xterm-ghostty breaks TUIs on machines without
    ///   Ghostty.app's terminfo installed (and over ssh regardless).
    /// - `scrollback-limit`: **not taste but arithmetic, and helm is the only
    ///   thing in the stack that can do it.** ghostty's own doc calls this "the
    ///   size of the scrollback buffer in bytes … **per terminal surface, not
    ///   for the entire application**" (`Config.zig` at the pinned 35e1a01), so
    ///   the number is spent once per pane the operator has *visited* and a
    ///   Ghostty config — written for one window — has no way to know how many
    ///   that is. helm does. That is why this is an override the operator's own
    ///   config cannot move, in either direction.
    ///
    ///   **Why 16 MiB, when it used to be 100 and ghostty's own default is 50 MB.**
    ///   The limit counts *page memory*, not text: a page is laid out as
    ///   `@sizeOf(Row) + @sizeOf(Cell) × cols` per row and both are
    ///   `packed struct(u64)` (`page.zig`, `Capacity.adjust`), so **one line of
    ///   history costs about 8 × (cols + 1) bytes** — 8.6 × with the page's style
    ///   and grapheme areas amortised in — however few characters are on it. Across
    ///   the pane widths helm's benches actually produce, 80 to 200 columns, 16 MiB
    ///   is **10,000–24,000 lines** a pane, 200–500 screenfuls of scroll-up. 100 MiB
    ///   was 60,000–150,000, which nobody scrolls, on a ceiling that multiplied:
    ///   a seventeen-pane day reserved ~1.7 GiB where it now reserves ~272 MiB.
    ///
    ///   **And the ceiling is spendable, which is the part worth measuring.** 33.9 MB
    ///   of text — 300,000 lines — written into *one* pane of an isolated instance,
    ///   resident set before and after, settled over a minute of idle:
    ///
    ///   | limit  | before   | after    | delta    |
    ///   | ------ | -------- | -------- | -------- |
    ///   | 100 MiB| 147.4 MB | 253.9 MB | +106.5 MB |
    ///   | 16 MiB | 183.8 MB | 203.0 MB | **+19.2 MB** |
    ///
    ///   Both deltas are their configured ceiling plus a little, so a single pane can
    ///   and does spend the whole of it — and 34 MB of text costing 106 MB of memory is
    ///   the 8-bytes-a-cell arithmetic above, visible from outside. Neither number moved
    ///   while the instance sat idle: `scrollback-compression` defaults on at the pinned
    ///   ghostty, and it bought nothing observable here, so nothing in this decision
    ///   leans on it.
    ///
    ///   **The reason the smaller number is safe is that scrollback is not the
    ///   archive.** The transcript on disk is
    ///   (`~/.claude/projects/<slug>/<sessionId>.jsonl`) and the chat face already
    ///   reads it, so history that scrolls off a pane is lost from the *pane*, not
    ///   from helm. Scrollback only has to cover "scroll up and see what just
    ///   happened".
    ///
    ///   Note the direction: at 16 MiB helm is holding a pane **below** ghostty's
    ///   50 MB default rather than above it, which is the opposite of what this
    ///   override did before (#106). An operator who has set a bigger
    ///   `scrollback-limit` in their own config is capped by it, deliberately —
    ///   their number was chosen for one window, and helm has N.
    /// - `window-padding-*`: **layout, not preference.** These are the insets
    ///   the grid is drawn inside, and they have to agree with the chrome
    ///   wrapped around it — the strip above uses the same 9, so the first
    ///   character of a line stands where a tab's label does. Left to the
    ///   operator's config they were whatever a standalone Ghostty window
    ///   wanted, which for a full-screen terminal is often nothing at all: text
    ///   flush against the pane edge while every element around it breathes.
    /// - `font-size`: only once ⌘+/⌘- has been used. A size chosen inside helm
    ///   is a more direct statement of intent than a config written months ago,
    ///   so it outranks even the user config.
    static var sessionOverrides: TerminalConfiguration {
        let chosenFontSize = persistedFontSize
        return TerminalConfiguration { builder in
            builder.withCustom("term", "xterm-256color")
            builder.withCustom("scrollback-limit", "16777216")  // 16 MiB — see above
            builder.withWindowPaddingX(paneInset.horizontal)
            builder.withWindowPaddingY(paneInset.vertical)
            if let chosenFontSize { builder.withFontSize(chosenFontSize) }
        }
    }

    /// The grid's insets, in points — the chrome's own numbers, so the terminal sits in the
    /// same rhythm as the strip above it rather than in whatever a standalone Ghostty
    /// window was tuned for.
    nonisolated static let paneInset = (horizontal: 9, vertical: 4)

    /// Helm's baseline font size — the size helm's first ⌘+ steps up from when
    /// the user's config declares none of its own.
    static let baseFontSize: Float = 13

    /// Helm's own defaults: the BASE every terminal starts from, whether or not
    /// the user has a Ghostty config. A taller cell for breathing room (agent
    /// output is read, not just watched scroll past). Font family is left unset
    /// on purpose — libghostty falls back to its embedded JetBrains Mono, which
    /// beats anything named blindly.
    ///
    /// Padding used to be here, where the operator's config outranked it. It is a
    /// session override now — see `sessionOverrides` for why insets are layout
    /// rather than taste.
    ///
    /// **`copy-on-select = false` is here because ghostty's own default destroys the
    /// operator's clipboard in an embedded surface, and only in an embedded one (#297).**
    /// Measured, not reasoned about: a sentinel on `NSPasteboard.general`, one mouse drag
    /// across a line of terminal text, and the sentinel is gone — replaced by the dragged
    /// text, with nothing on screen to say so. What that costs is the most ordinary thing
    /// anyone does with a terminal: copy something in a browser, come to helm, drag across
    /// a line while reading, press ⌘V, and paste "does not work at all". It works
    /// perfectly; the clipboard it pastes is simply no longer the one that was copied.
    ///
    /// **The lie is one layer down and helm cannot reach it.** ghostty's default is
    /// `copy-on-select = true`, which means *the selection clipboard* — X11's middle-click
    /// buffer, which macOS does not have. Ghostty asks the host whether it has one, and the
    /// vendored AppKit wrapper answers yes (`supports_selection_clipboard = true`,
    /// `TerminalController+Config.swift`) and then ignores the parameter naming which
    /// clipboard to write, putting every selection on `NSPasteboard.general`
    /// (`TerminalController+Callbacks.swift`, `writeClipboard(userdata:clipboard:…)` —
    /// the `clipboard` argument is `_`). Ghostty.app answers no, which is why
    /// `copy-on-select = true` is a harmless no-op in a real macOS ghostty window and a
    /// clipboard eater in this one. `runtimeConfig` is private to the vendored controller,
    /// so turning the claim off is a vendor patch; turning the *feature* off is a config
    /// line, and it lands helm on exactly the behaviour Ghostty.app already has.
    ///
    /// **A default rather than a session override, deliberately.** An operator who wants
    /// selections on the clipboard writes `copy-on-select = clipboard` — ghostty's own
    /// spelling for the system clipboard, which routes through the standard channel and is
    /// correct here — and their config layers over this one (`GhosttyConfig.swift` tier 2).
    /// Forcing it in `sessionOverrides` would take a real preference away to fix a bug
    /// that is not theirs. ⌘C is untouched either way: `copy_to_clipboard` always names
    /// the standard clipboard.
    static let defaultConfiguration = TerminalConfiguration { builder in
        builder.withFontSize(baseFontSize)
        builder.withFontThicken(true)
        builder.withCursorStyle(.block)
        builder.withCursorStyleBlink(true)
        builder.withCustom("adjust-cell-height", "15%")
        builder.withCustom("copy-on-select", "false")
    }

    /// The terminal's colours, out of the same table the chrome spends.
    ///
    /// **This is the point of the palette being values.** The chrome resolves those tokens
    /// to `Color`s; here the same tokens render as `#rrggbb` ghostty config lines, so the
    /// grid and the strip above it cannot drift apart — there is nothing to keep in step.
    /// They were two hand-written sets of hexes before, and looked it.
    ///
    /// Light/dark follows helm's appearance override for free: the wrapper's NSView
    /// observes `effectiveAppearance` and re-resolves the theme itself, so switching
    /// appearance re-themes live terminals with no helm code and no reload.
    nonisolated static let terminalTheme = TerminalTheme(
        light: terminalColors(in: .light),
        dark: terminalColors(in: .dark)
    )

    /// One appearance's colour lines. Separate from `terminalTheme` so a test can render
    /// and read them without a ghostty controller or a window.
    nonisolated static func terminalColors(
        in appearance: Palette.Appearance
    ) -> TerminalConfiguration {
        let palette = Palette.helm
        let surface = palette.surface.value(in: appearance).hex
        return TerminalConfiguration { builder in
            builder.withBackground(surface)
            builder.withForeground(palette.textPrimary.value(in: appearance).hex)
            // The cursor is the one place the accent earns a whole element: it is the
            // operator's own position, it is always on screen, and nothing else in the grid
            // competes with it. `cursor-text` is the surface so the character underneath a
            // block cursor stays legible rather than inverting to something arbitrary.
            builder.withCursorColor(palette.accent.value(in: appearance).hex)
            builder.withCursorText(surface)
            builder.withSelectionBackground(palette.selection.value(in: appearance).hex)
            builder.withSelectionForeground(palette.textPrimary.value(in: appearance).hex)
            // The sixteen, so the content agrees with the frame — see `AnsiPalette` for why
            // helm took them over and what "hue identity" constrains.
            for entry in AnsiPalette.helm.ordered {
                builder.withPalette(entry.index, color: entry.token.value(in: appearance).hex)
            }
            // **Formatted here, never through the typed `withBackgroundOpacity`.** The
            // wrapper renders a `Double` with `.formatted(.number…)`, which is
            // locale-sensitive and emits "0,93" under a comma-decimal locale — a hard
            // ghostty config error rather than a wrong number, and one that would only ever
            // appear on somebody else's machine. `locale: nil` is what makes this the C
            // formatting the config file wants. Same hazard `minimum-contrast` dodges.
            builder.withCustom(
                "background-opacity",
                String(format: "%.2f", locale: nil, backgroundOpacity(in: appearance)))
            if appearance == .light {
                // A floor under the ANSI sixteen on paper. helm tunes them for its own
                // surface (`AnsiPaletteTests` pins the ratios), so this now guards against
                // a program that sets its own colours rather than against the palette.
                builder.withCustom("minimum-contrast", "1.2")
            }
        }
    }

    /// How opaque the grid's background is — the one knob that reaches the Metal layer.
    ///
    /// **Native, because nothing else can be.** SwiftUI vibrancy cannot filter a backdrop
    /// another renderer draws over, so the chrome's trick does not work here; ghostty's own
    /// `background-opacity` does, because the wrapper already builds the Metal layer with
    /// `isOpaque = false` and the renderer honours the alpha. What the grid then composites
    /// against is helm's business, and `TerminalBackdrop` is the answer: a frosted plane
    /// behind the surface, so what comes through is a soft wash rather than sharp wallpaper.
    /// `background-blur` is not that answer — libghostty parses the key and does nothing
    /// with it, because in Ghostty.app the blur is a window effect the *app* applies, and
    /// this window is helm's.
    ///
    /// **Measured on a running build, twice, and the first answer was wrong.** 0.93 was
    /// tried first and looked right in the source: the grid *was* translucent and the code
    /// *was* correct. Sampling the composited pixels said it moved 1 to 2 luminance levels
    /// while the chrome beside it moved 9 to 17 — translucent, and still reading as a slab.
    /// The frosted plane is a heavily darkened wash, so a few percent of it is nothing.
    ///
    /// **Light pays more for this than dark, which is why there are two numbers.** Nearly
    /// everything a window sits over is darker than paper, so the opacity that gives a dark
    /// surface depth just makes a light one dingy: at 0.86 the light grid measured `#ebebea`
    /// against its own `#fbfaf8` — grey where it should be warm.
    ///
    /// Neither goes lower. This is a wall of small monospace read for hours, and every point
    /// of opacity spent is contrast taken off the one surface helm exists to render. The
    /// worst-case text contrast at these values measured 11.8 dark and 14.6 light, and that
    /// headroom is what makes them safe rather than merely pretty.
    nonisolated static func backgroundOpacity(in appearance: Palette.Appearance) -> Double {
        switch appearance {
        case .light: 0.92
        case .dark: 0.86
        }
    }

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
            guard DefaultsDomain.store.object(forKey: fontSizeDefaultsKey) != nil else {
                return nil
            }
            return Float(DefaultsDomain.store.double(forKey: fontSizeDefaultsKey))
        }
        set {
            guard let newValue else {
                return DefaultsDomain.store.removeObject(forKey: fontSizeDefaultsKey)
            }
            DefaultsDomain.store.set(Double(newValue), forKey: fontSizeDefaultsKey)
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
        // Only tabs the operator cannot see get marked — a bell on a terminal they
        // are looking at needs no indicator (and would linger stale otherwise).
        guard !isVisible else { return }
        hasBell = true
    }

    /// ⌘-click on a link in the grid. The allowlist (TerminalURLPolicy) is
    /// the whole security story: terminal content is untrusted, so anything
    /// but http/https/file/mailto is dropped silently.
    ///
    /// It used to point out of the app: every link went to `NSWorkspace`, so a rendered
    /// report tabbed you into a browser — the trip helm exists to absorb. A link to
    /// something the canvas renders now opens **in helm** instead.
    ///
    /// **Offer, not push.** helm opens it only when you ⌘-click. Nothing appears
    /// unbidden — it is not helm's job to rearrange the bench on the operator's behalf.
    ///
    /// **This comment used to call itself "the agent→helm channel", and that was wrong
    /// in its main case (#124).** Two independent measurements, 2026-08-07, on a live
    /// spool-spawned Claude agent in an isolated helm:
    ///
    /// 1. **Claude Code's TUI captures the mouse**, so a ⌘-click is consumed before helm
    ///    exists in the path — no `GHOSTTY_ACTION_OPEN_URL`, no hover, nothing to handle.
    ///    Measured off the pty: it sets `?1000h ?1002h ?1003h ?1006h` at startup. It is
    ///    **agent-specific, not a property of TUIs** — `pi` and `codex` set no mouse
    ///    tracking at all, so a link in one of *their* panes still reaches here.
    /// 2. **Inside a Claude session there is no hyperlink to click in the first place.**
    ///    The agent ran `printf` emitting a real OSC 8 sequence; the TUI re-renders
    ///    everything it prints, and what reached the grid was plain styled text. So the
    ///    capture is not even the binding constraint for the case #124 describes.
    ///
    /// The agent→helm channel is `push.sh` (#125, #170, #184): an agent pushes the
    /// artifact and helm offers it as a tab, needing no click and no operator at the pane.
    /// This method stays exactly as it is — a link printed from a *shell* still works,
    /// which is a path #124 required not to regress.
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
            HelmCommand.openCanvasFile(validated).post()
        case .canvasURL:
            HelmCommand.openCanvasURL(validated).post()
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
            isVisible: isVisible
        )
    }

    /// OSC 9 / OSC 777 desktop notification. Delivered only when helm is in
    /// the background or the pane is off screen; title is the tab's, body is
    /// the message (OSC 9 carries only a body — fall back to the sequence's
    /// title so neither form delivers an empty banner).
    /// Also helm's canvas-push channel. See `CanvasPush` for why this sequence and not one
    /// of helm's own: helm never sees OSC *sequences*, only ghostty's *parsed actions*, and
    /// this is the only action that both fires on output and carries arbitrary text.
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        switch CanvasPush.classify(title: title, body: body) {
        case let .open(url):
            HelmCommand.pushCanvasFile(
                CanvasPushRequest(
                    artifact: url, workspacePath: workspacePath,
                    // This session is the agent that asked, and this is the only place that is
                    // known — see `CanvasPushRequest.origin`.
                    origin: CanvasOrigin(terminal: id))
            ).post()
            return
        case let .refused(why):
            // Ungated on purpose. The gate below suppresses *ambient* notifications while
            // you are already looking at the pane — right for "build finished", wrong for
            // the refusal of something an agent explicitly asked for. A silent refusal is
            // indistinguishable from a channel that does not work, which is #124's whole
            // failure mode.
            guard refusalThrottle.allows(at: Date()) else { return }
            TerminalNotifier.shared.deliver(title: displayTitle, body: why)
            return
        case .notAPush:
            break
        }

        guard
            TerminalNotificationGate.shouldDeliver(
                appIsActive: NSApp.isActive,
                paneIsVisible: isVisible
            )
        else { return }
        let message = body.isEmpty ? title : body
        guard !message.isEmpty else { return }
        TerminalNotifier.shared.deliver(title: displayTitle, body: message)
    }
}

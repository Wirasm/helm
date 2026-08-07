import XCTest

@testable import Helm

/// Pure config plumbing: user-config discovery order, include sanitizing, and
/// the controller composition (user config as base, helm overrides after) —
/// all headless, using real ghostty controllers where composition is asserted
/// (proven safe by GhosttySmokeTests).
final class GhosttyConfigTests: XCTestCase {
    // MARK: - Discovery

    func testConfigPathsMirrorGhosttyLoadOrder() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertEqual(
            GhosttyUserConfig.configPaths(home: home, xdgConfigHome: nil),
            [
                "/Users/example/.config/ghostty/config",
                "/Users/example/Library/Application Support/com.mitchellh.ghostty/config",
            ]
        )
    }

    func testConfigPathsRespectXDGConfigHome() {
        let home = URL(fileURLWithPath: "/Users/example")
        let paths = GhosttyUserConfig.configPaths(home: home, xdgConfigHome: "/xdg")
        XCTAssertEqual(paths[0], "/xdg/ghostty/config")
    }

    func testLoadReturnsNilWithoutAnyConfigFile() {
        XCTAssertNil(GhosttyUserConfig.load(paths: ["/nonexistent/ghostty/config"]))
    }

    func testLoadConcatenatesInOrderSoLaterFilesWin() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-ghostty-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let xdg = dir.appendingPathComponent("xdg-config")
        let appSupport = dir.appendingPathComponent("appsupport-config")
        try "font-size = 12".write(to: xdg, atomically: true, encoding: .utf8)
        try "font-size = 16".write(to: appSupport, atomically: true, encoding: .utf8)

        let loaded = GhosttyUserConfig.load(paths: [xdg.path, appSupport.path])
        // Ghostty's last-value-wins rule makes the Application Support file
        // authoritative — it must come after the XDG one.
        XCTAssertEqual(loaded, "font-size = 12\nfont-size = 16")
    }

    // MARK: - Sanitizing

    func testSanitizeDropsOnlyConfigFileIncludes() {
        let contents = """
            font-size = 14
            config-file = extra-config
              config-file=other
            # a comment mentioning config-file = stays
            theme = light:x,dark:y
            """
        XCTAssertEqual(
            GhosttyUserConfig.sanitize(contents),
            """
            font-size = 14
            # a comment mentioning config-file = stays
            theme = light:x,dark:y
            """
        )
    }

    // MARK: - font-size declaration

    func testDeclaredFontSizeReadsTheLastValue() {
        XCTAssertEqual(GhosttyUserConfig.declaredFontSize(in: "font-size = 12"), 12)
        XCTAssertEqual(
            GhosttyUserConfig.declaredFontSize(in: "font-size = 12\nfont-size=16"),
            16,
            "ghostty's last-value-wins rule applies to the baseline too"
        )
    }

    func testDeclaredFontSizeIgnoresCommentsOtherKeysAndJunk() {
        XCTAssertNil(GhosttyUserConfig.declaredFontSize(in: "# font-size = 20"))
        XCTAssertNil(GhosttyUserConfig.declaredFontSize(in: "adjust-cell-height = 15%"))
        XCTAssertNil(GhosttyUserConfig.declaredFontSize(in: "font-size = huge"))
        XCTAssertNil(GhosttyUserConfig.declaredFontSize(in: "keybind = shift+enter=text:\\n"))
    }

    // MARK: - Controller composition

    /// The regression this branch exists for: a user config that mentions ONE
    /// key must not cost the user every default helm sets.
    @MainActor
    func testHelmDefaultsSurviveAUserConfigThatDoesNotMentionThem() {
        let controller = TerminalSession.makeController(
            userConfig: "keybind = shift+enter=text:\\n"
        )
        XCTAssertNil(controller.lastConfigurationIssue)

        let rendered = controller.renderedConfig
        XCTAssertTrue(rendered.contains("adjust-cell-height = 15%"), rendered)
        XCTAssertTrue(rendered.contains("font-thicken = true"), rendered)
        XCTAssertTrue(rendered.contains("scrollback-limit = \(Self.scrollbackLimit)"), rendered)
        XCTAssertTrue(rendered.contains("keybind = shift+enter=text:\\n"), rendered)
        // `window-padding-x` was asserted here and has moved, not vanished: it stopped
        // being a default the operator outranks and became an override that outranks them
        // (`testTheOperatorsConfigCannotTakeTheGridsInsets`). `font-thicken` takes its
        // place as the "a default helm still yields on" case this test is about.
    }

    @MainActor
    func testUserConfigLayersOverHelmDefaultsAndSessionOverridesWinLast() {
        let controller = TerminalSession.makeController(userConfig: "font-size = 21")
        XCTAssertNil(controller.lastConfigurationIssue)

        let rendered = controller.renderedConfig
        guard let helmDefault = rendered.range(of: "font-size = 13"),
            let user = rendered.range(of: "font-size = 21"),
            let override = rendered.range(of: "term = xterm-256color")
        else {
            return XCTFail("expected all three tiers in: \(rendered)")
        }
        XCTAssertLessThan(
            helmDefault.lowerBound, user.lowerBound,
            "the user config must render AFTER helm's defaults so their keys win"
        )
        XCTAssertLessThan(
            user.lowerBound, override.lowerBound,
            "helm's session overrides must render AFTER the user config so they win"
        )
    }

    @MainActor
    func testDefaultsApplyWithoutUserConfig() {
        let controller = TerminalSession.makeController(userConfig: nil)
        XCTAssertNil(controller.lastConfigurationIssue)
        XCTAssertTrue(
            controller.renderedConfig.contains("scrollback-limit = \(Self.scrollbackLimit)"))
        XCTAssertTrue(controller.renderedConfig.contains("adjust-cell-height = 15%"))
        XCTAssertTrue(controller.renderedConfig.contains("term = xterm-256color"))
    }

    // MARK: - copy-on-select

    /// #297: a mouse selection in a pane must not replace the system clipboard.
    ///
    /// The bug this pins is one layer below helm and invisible from it: ghostty's default
    /// `copy-on-select = true` targets the *selection* clipboard, the vendored AppKit
    /// wrapper claims macOS has one and then writes every selection to
    /// `NSPasteboard.general` regardless. So dragging across a line of terminal output
    /// silently destroyed whatever the operator had copied somewhere else, and the ⌘V that
    /// followed pasted terminal text — which reads exactly like "paste is broken".
    ///
    /// Asserted on the rendered config rather than on a live surface because that is where
    /// helm's decision actually is; the live half — sentinel on the pasteboard, drag, read
    /// it back — is in the PR, and no unit test can reach it (a selection needs a window,
    /// a surface and a mouse).
    @MainActor
    func testHelmTurnsCopyOnSelectOffSoASelectionCannotEatTheClipboard() {
        let controller = TerminalSession.makeController(userConfig: nil)
        XCTAssertNil(controller.lastConfigurationIssue)
        XCTAssertTrue(
            controller.renderedConfig.contains("copy-on-select = false"),
            controller.renderedConfig)
    }

    /// …and it is a **default**, not an override: an operator who genuinely wants
    /// selections on the clipboard says so with ghostty's own spelling for the system
    /// clipboard, and their config wins.
    ///
    /// This is the control that fails if the fix overshoots into `sessionOverrides` — the
    /// tier helm's scrollback and insets live in, which the operator cannot move.
    @MainActor
    func testTheOperatorCanStillAskForCopyOnSelect() {
        let controller = TerminalSession.makeController(userConfig: "copy-on-select = clipboard")
        XCTAssertNil(controller.lastConfigurationIssue)

        let rendered = controller.renderedConfig
        guard let helmDefault = rendered.range(of: "copy-on-select = false"),
            let user = rendered.range(of: "copy-on-select = clipboard")
        else {
            return XCTFail("expected both copy-on-select values in: \(rendered)")
        }
        XCTAssertLessThan(
            helmDefault.lowerBound, user.lowerBound,
            "helm's default must render BEFORE the operator's config so theirs wins")
    }

    // MARK: - Scrollback

    /// **16 MiB, spelled as the quantity rather than as 16777216.** A digit wrong in a
    /// byte count is invisible in review and reads as a deliberate number afterwards;
    /// written this way the test fails on the intent, and the derivation that chose 16
    /// lives with the value in `TerminalSession.sessionOverrides`.
    private static let scrollbackLimit = 16 * 1024 * 1024

    /// The ceiling is helm's in **both** directions, and this used to assert only one
    /// of them.
    ///
    /// It was `testUserConfigCannotShrinkTheAgentScrollback`, and while helm's number
    /// was 100 MiB — above ghostty's own 50 MB default — "the operator cannot move it"
    /// and "the operator cannot shrink it" were the same claim, so a one-sided test
    /// looked complete. At 16 MiB helm is below that default, so the interesting case
    /// is the other one: an operator whose config asks for **more** is now capped, and
    /// nothing asserted that before. Both are here because the property is neither
    /// "raise" nor "cap" — it is that the limit is a per-application decision (#106),
    /// and an application-level decision that a per-window config can move is not one.
    @MainActor
    func testTheOperatorsConfigCannotMoveTheScrollbackCeilingEitherWay() {
        for asked in ["1000", "999999999"] {
            let controller = TerminalSession.makeController(
                userConfig: "scrollback-limit = \(asked)")
            XCTAssertNil(controller.lastConfigurationIssue)

            let rendered = controller.renderedConfig
            guard let user = rendered.range(of: "scrollback-limit = \(asked)"),
                let helm = rendered.range(of: "scrollback-limit = \(Self.scrollbackLimit)")
            else {
                return XCTFail("expected both scrollback values in: \(rendered)")
            }
            XCTAssertLessThan(
                user.lowerBound, helm.lowerBound,
                "helm's scrollback must win over a config asking for \(asked)")
        }
    }

    // MARK: - Persisted font size

    @MainActor
    func testPersistedFontSizeIsAppliedToNewSessionsAndOutranksTheUserConfig() {
        let previous = TerminalSession.persistedFontSize
        defer { TerminalSession.persistedFontSize = previous }

        TerminalSession.persistedFontSize = 18
        let rendered =
            TerminalSession
            .makeController(userConfig: "font-size = 21")
            .renderedConfig

        guard let user = rendered.range(of: "font-size = 21"),
            let chosen = rendered.range(of: "font-size = 18")
        else {
            return XCTFail("expected both sizes in: \(rendered)")
        }
        XCTAssertLessThan(
            user.lowerBound, chosen.lowerBound,
            "a size chosen inside helm outranks the user's config"
        )
    }

    @MainActor
    func testPersistedFontSizeRoundTripsAndClears() {
        let previous = TerminalSession.persistedFontSize
        defer { TerminalSession.persistedFontSize = previous }

        TerminalSession.persistedFontSize = 17
        XCTAssertEqual(TerminalSession.persistedFontSize, 17)
        XCTAssertEqual(TerminalSession.effectiveFontSize, 17)

        TerminalSession.persistedFontSize = nil
        XCTAssertNil(TerminalSession.persistedFontSize)
        XCTAssertEqual(
            TerminalSession.effectiveFontSize,
            TerminalSession.declaredUserFontSize ?? TerminalSession.baseFontSize,
            "cleared → fall back to the user's declared size, else helm's baseline"
        )
    }

    // MARK: - Colour

    /// The point of the palette being values: the terminal's colours are not a second set
    /// of hexes that has to be kept in step with the chrome's, they are the same tokens
    /// rendered as ghostty config lines. Asserted against `Palette.helm` rather than
    /// against literals for exactly that reason — a literal here would be the drift.
    func testTerminalColoursComeOutOfThePalette() {
        for appearance in Palette.Appearance.allCases {
            let rendered = TerminalSession.terminalColors(in: appearance).rendered
            let palette = Palette.helm
            XCTAssertTrue(
                rendered.contains("background = \(palette.surface.value(in: appearance).hex)"),
                rendered)
            XCTAssertTrue(
                rendered.contains("foreground = \(palette.textPrimary.value(in: appearance).hex)"),
                rendered)
            XCTAssertTrue(
                rendered.contains("cursor-color = \(palette.accent.value(in: appearance).hex)"),
                rendered)
            // The two that carry a legibility rule rather than a colour preference, and so
            // are the two most worth pinning. `cursor-text` is the SURFACE: a block cursor
            // covers a character, and the character has to stay readable under it — the
            // line above sets `cursor-color` to the accent, so the obvious copy-paste slip
            // is accent-on-accent, which is invisible and looks deliberate.
            XCTAssertTrue(
                rendered.contains("cursor-text = \(palette.surface.value(in: appearance).hex)"),
                rendered)
            XCTAssertTrue(
                rendered.contains(
                    "selection-background = \(palette.selection.value(in: appearance).hex)"),
                rendered)
            XCTAssertTrue(
                rendered.contains(
                    "selection-foreground = \(palette.textPrimary.value(in: appearance).hex)"),
                rendered)
        }
    }

    /// Light only, and the raw-string form: the wrapper renders Doubles through a
    /// locale-sensitive formatter, which produces "1,2" under a comma-decimal locale and
    /// that is a hard ghostty config error rather than a wrong number.
    func testMinimumContrastIsSetInLightOnly() {
        XCTAssertTrue(
            TerminalSession.terminalColors(in: .light).rendered.contains(
                "minimum-contrast = 1.2"))
        XCTAssertFalse(
            TerminalSession.terminalColors(in: .dark).rendered.contains("minimum-contrast"))
    }

    /// **The behaviour that changed.** helm's theme used to go empty whenever a user config
    /// existed, so a helm terminal wore the operator's Ghostty colours and agreed with
    /// nothing else on screen. Colour is helm's now — the theme renders last, so it wins.
    @MainActor
    func testHelmsColoursWinOverAUserConfigThatSetsItsOwn() {
        let controller = TerminalSession.makeController(userConfig: "background = #ff0000")
        XCTAssertNil(controller.lastConfigurationIssue)

        // Read line by line, and compared on the LAST one rather than on a specific hex:
        // the controller renders whichever appearance is current, and the rule being pinned
        // is "helm has the last word", not which of its two values it happens to say.
        let rendered = controller.renderedConfig
        let backgrounds =
            rendered
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("background = ") }
        let palette = Palette.helm.surface
        XCTAssertEqual(backgrounds.first, "background = #ff0000", rendered)
        XCTAssertTrue(
            [palette.light.hex, palette.dark.hex]
                .map { "background = \($0)" }
                .contains(backgrounds.last ?? ""),
            "the final word on background must be a palette token: \(rendered)"
        )
    }

    /// The other half of the same decision, and the one that must not regress: what helm
    /// took is colour and layout. Everything about the TEXT ITSELF is still the operator's.
    ///
    /// **This test used to assert the opposite about `palette`.** It required a user's
    /// `palette = 1=…` to survive, because the sixteen ANSI entries were on the operator's
    /// side of the line. They are helm's now — see `AnsiPalette` and `GhosttyConfig`'s
    /// header for why the earlier reasoning was wrong — so the assertion is restated rather
    /// than dropped: the subject is still "what does a user config keep", the answer moved.
    @MainActor
    func testTheOperatorKeepsTheTextItself() {
        let controller = TerminalSession.makeController(
            userConfig: "font-family = Menlo\nfont-thicken = false\nkeybind = shift+enter=text:\\n"
        )
        XCTAssertNil(controller.lastConfigurationIssue)

        let rendered = controller.renderedConfig
        XCTAssertTrue(rendered.contains("font-family = Menlo"), rendered)
        XCTAssertTrue(rendered.contains("keybind = shift+enter=text:\\n"), rendered)
        guard let helmThicken = rendered.range(of: "font-thicken = true"),
            let userThicken = rendered.range(of: "font-thicken = false")
        else {
            return XCTFail("expected both font-thicken values in: \(rendered)")
        }
        XCTAssertLessThan(
            helmThicken.lowerBound, userThicken.lowerBound,
            "helm's font tuning is a default the operator outranks, not an override"
        )
    }

    /// The sixteen, now on helm's side of the line: a user's entry renders, and helm's
    /// renders after it.
    @MainActor
    func testHelmsAnsiPaletteWinsOverTheOperatorsOwn() {
        let controller = TerminalSession.makeController(userConfig: "palette = 1=#abcdef")
        XCTAssertNil(controller.lastConfigurationIssue)

        let rendered = controller.renderedConfig
        let reds =
            rendered
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("palette = 1=") }
        let ansi = AnsiPalette.helm.red
        XCTAssertEqual(reds.first, "palette = 1=#abcdef", rendered)
        XCTAssertTrue(
            [ansi.light.hex, ansi.dark.hex].map { "palette = 1=\($0)" }.contains(reds.last ?? ""),
            "the last word on palette 1 must be helm's red: \(rendered)"
        )
    }

    /// All sixteen, every one of them, in both appearances — a missing index is a colour
    /// left at ghostty's default in the middle of a derived set, which reads as a theme
    /// choice rather than as a gap.
    func testEverySixteenAnsiEntriesRender() {
        for appearance in Palette.Appearance.allCases {
            let rendered = TerminalSession.terminalColors(in: appearance).rendered
            for entry in AnsiPalette.helm.ordered {
                XCTAssertTrue(
                    rendered.contains(
                        "palette = \(entry.index)=\(entry.token.value(in: appearance).hex)"),
                    "\(entry.name) missing in \(appearance): \(rendered)"
                )
            }
        }
    }

    // MARK: - Layout

    /// Padding is layout, not preference: the grid's insets have to agree with the chrome
    /// wrapped around it, so a config tuned for a standalone Ghostty window — frequently no
    /// padding at all, which puts text flush against the pane edge — cannot win them.
    @MainActor
    func testTheOperatorsConfigCannotTakeTheGridsInsets() {
        let controller = TerminalSession.makeController(
            userConfig: "window-padding-x = 0\nwindow-padding-y = 0")
        XCTAssertNil(controller.lastConfigurationIssue)

        let rendered = controller.renderedConfig
        let inset = TerminalSession.paneInset
        guard let user = rendered.range(of: "window-padding-x = 0"),
            let helm = rendered.range(of: "window-padding-x = \(inset.horizontal)")
        else {
            return XCTFail("expected both padding values in: \(rendered)")
        }
        XCTAssertLessThan(user.lowerBound, helm.lowerBound, "helm's insets must render last")
        XCTAssertTrue(
            rendered.contains("window-padding-y = \(inset.vertical)"), rendered)
    }

    // MARK: - Translucency

    /// **Formatted, not `.formatted()`.** The wrapper's typed `withBackgroundOpacity` runs a
    /// `Double` through a locale-sensitive formatter, which emits "0,93" under a
    /// comma-decimal locale — a hard ghostty config error that would only ever appear on
    /// somebody else's machine. This pins the decimal point itself, under a locale that
    /// would otherwise produce a comma.
    func testBackgroundOpacityRendersWithADecimalPointInEveryLocale() {
        for appearance in Palette.Appearance.allCases {
            let expected =
                "background-opacity = "
                + String(
                    format: "%.2f", locale: nil,
                    TerminalSession.backgroundOpacity(in: appearance))
            XCTAssertTrue(expected.contains("."), "the test's own baseline must use a point")
            let rendered = TerminalSession.terminalColors(in: appearance).rendered
            XCTAssertTrue(rendered.contains(expected), rendered)
            XCTAssertFalse(rendered.contains("background-opacity = 0,"), rendered)
        }
    }

    /// Translucent enough to read as one material with the chrome, opaque enough that a wall
    /// of small monospace does not pay for it. Both ends are real failures, so both are
    /// pinned — these are the numbers a future "let's make it glassier" edit has to argue
    /// with rather than quietly slide past.
    func testBackgroundOpacityStaysInTheLegibleRange() {
        for appearance in Palette.Appearance.allCases {
            let opacity = TerminalSession.backgroundOpacity(in: appearance)
            XCTAssertGreaterThanOrEqual(
                opacity, 0.84,
                "\(appearance): below this the wallpaper competes with terminal text")
            XCTAssertLessThanOrEqual(
                opacity, 0.94,
                "\(appearance): above this it is a solid slab inside a translucent frame again")
        }
    }

    /// Paper loses more to translucency than ink does — nearly everything a window sits over
    /// is darker than a light surface, so the value that gives dark depth makes light dingy.
    /// Measured: at dark's opacity the light grid came out `#ebebea` against its own
    /// `#fbfaf8`. If these two ever converge, that asymmetry has been forgotten.
    func testLightIsHeldMoreOpaqueThanDark() {
        XCTAssertGreaterThan(
            TerminalSession.backgroundOpacity(in: .light),
            TerminalSession.backgroundOpacity(in: .dark)
        )
    }

    // MARK: - Truecolor

    /// `term` stays `xterm-256color` — the embedded xcframework ships no terminfo, so
    /// ghostty's own TERM breaks TUIs — and 24-bit colour is therefore something helm has
    /// to *say*. It was arriving by accident before, inherited from an unrelated variable
    /// helm sets for shell integration, which is one refactor away from silently costing
    /// every colour in the palette its precision.
    @MainActor
    func testEveryTerminalChildIsToldItHasTruecolor() {
        let manager = TerminalManager()
        manager.activate(workspacePath: WorkspacePath("/tmp/helm-truecolor"))
        guard let session = manager.sessions.first else {
            return XCTFail("activating a workspace opens one terminal")
        }

        let environment = session.hostView.configuration.envVars
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(environment["TERM_PROGRAM"], "ghostty")
        XCTAssertTrue(
            TerminalSession.sessionOverrides.rendered.contains("term = xterm-256color"),
            "TERM must stay pinned — the env vars are what carry the colour depth"
        )
    }

    @MainActor
    func testValidationCatchesBrokenUserConfig() {
        XCTAssertFalse(
            TerminalSession.validateUserConfig("font-size = not-a-number"),
            "a config ghostty rejects must fail validation (helm then falls back to defaults)"
        )
        XCTAssertTrue(TerminalSession.validateUserConfig("font-size = 14"))
    }
}

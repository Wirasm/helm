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
        XCTAssertTrue(rendered.contains("window-padding-x = 8"), rendered)
        XCTAssertTrue(rendered.contains("scrollback-limit = 104857600"), rendered)
        XCTAssertTrue(rendered.contains("keybind = shift+enter=text:\\n"), rendered)
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
        XCTAssertTrue(controller.renderedConfig.contains("scrollback-limit = 104857600"))
        XCTAssertTrue(controller.renderedConfig.contains("adjust-cell-height = 15%"))
        XCTAssertTrue(controller.renderedConfig.contains("term = xterm-256color"))
    }

    /// Scrollback is a job requirement, not taste: an agent transcript outruns
    /// a shell-tuned default, so a user config must not be able to shrink it.
    @MainActor
    func testUserConfigCannotShrinkTheAgentScrollback() {
        let controller = TerminalSession.makeController(userConfig: "scrollback-limit = 1000")
        XCTAssertNil(controller.lastConfigurationIssue)

        let rendered = controller.renderedConfig
        guard let user = rendered.range(of: "scrollback-limit = 1000"),
              let helm = rendered.range(of: "scrollback-limit = 104857600")
        else {
            return XCTFail("expected both scrollback values in: \(rendered)")
        }
        XCTAssertLessThan(user.lowerBound, helm.lowerBound, "helm's scrollback must win")
    }

    // MARK: - Persisted font size

    @MainActor
    func testPersistedFontSizeIsAppliedToNewSessionsAndOutranksTheUserConfig() {
        let previous = TerminalSession.persistedFontSize
        defer { TerminalSession.persistedFontSize = previous }

        TerminalSession.persistedFontSize = 18
        let rendered = TerminalSession
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

    @MainActor
    func testValidationCatchesBrokenUserConfig() {
        XCTAssertFalse(
            TerminalSession.validateUserConfig("font-size = not-a-number"),
            "a config ghostty rejects must fail validation (helm then falls back to defaults)"
        )
        XCTAssertTrue(TerminalSession.validateUserConfig("font-size = 14"))
    }
}

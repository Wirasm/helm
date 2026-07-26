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

    // MARK: - Controller composition

    @MainActor
    func testUserConfigIsBaseWithHelmOverridesAfterIt() {
        let controller = TerminalSession.makeController(userConfig: "font-size = 21")
        XCTAssertNil(controller.lastConfigurationIssue)

        let rendered = controller.renderedConfig
        guard let user = rendered.range(of: "font-size = 21"),
              let override = rendered.range(of: "term = xterm-256color")
        else {
            return XCTFail("user config or helm override missing from: \(rendered)")
        }
        XCTAssertLessThan(
            user.lowerBound, override.lowerBound,
            "helm overrides must render AFTER the user config so they win"
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

    @MainActor
    func testValidationCatchesBrokenUserConfig() {
        XCTAssertFalse(
            TerminalSession.validateUserConfig("font-size = not-a-number"),
            "a config ghostty rejects must fail validation (helm then falls back to defaults)"
        )
        XCTAssertTrue(TerminalSession.validateUserConfig("font-size = 14"))
    }
}

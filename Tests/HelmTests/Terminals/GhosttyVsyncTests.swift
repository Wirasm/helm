import GhosttyKit
import XCTest

@testable import GhosttyTerminal
@testable import Helm

/// #495: Ghostty's vsync is a `CVDisplayLink` its renderer thread starts and stops, and
/// `CVDisplayLinkStop` can block forever after a display reconfiguration. The wedged
/// renderer stops draining its mailbox, and the next click that focuses the pane hangs
/// the main thread in `ghostty_surface_set_focus`. helm paces its own draws, so the
/// renderer must never get a link, whatever the operator's config asks for.
final class GhosttyVsyncTests: XCTestCase {
    /// Read back from ghostty's parsed config rather than from our rendered text, so a
    /// misspelt key fails here instead of being ignored.
    @MainActor
    func testTheRendererNeverRunsItsOwnDisplayLink() {
        for userConfig in [nil, "window-vsync = true"] {
            let controller = TerminalSession.makeController(userConfig: userConfig)
            XCTAssertNil(controller.lastConfigurationIssue)

            var vsync = true
            let key = "window-vsync"
            let found = ghostty_config_get(controller.config, &vsync, key, UInt(key.utf8.count))
            XCTAssertTrue(found, "ghostty does not know \(key)")
            XCTAssertFalse(vsync, "window-vsync is on with user config \(userConfig ?? "none")")
        }
    }
}

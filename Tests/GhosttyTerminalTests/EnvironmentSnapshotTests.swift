import Darwin
import XCTest

@testable import GhosttyTerminal

/// Ghostty keeps the environment `ghostty_init` saw and reads it again on every config load
/// (`GHOSTTY_MAC_LAUNCH_SOURCE`, in `ghostty_config_finalize`). Before the wrapper handed it a
/// copy, it kept `environ` itself, by pointer and length, so a `setenv` or `unsetenv` anywhere
/// in the process afterwards left it reading a shifted or freed array, and the next controller
/// crashed inside ghostty. A full `swift test` did that partway through, because a few helm
/// tests set and unset variables.
@MainActor
final class EnvironmentSnapshotTests: XCTestCase {
    /// `unsetenv` of a variable that existed at `ghostty_init` shifts the live array down in
    /// place, so an uncopied snapshot's last entry becomes the terminating NULL and the next
    /// config load dereferences it. Deterministic when this test is the first to start ghostty
    /// (`--filter EnvironmentSnapshotTests`). Later in a full run the array may have been
    /// reallocated since, and the unfixed failure is a read of freed memory instead.
    func testTheEnvironmentCanChangeAfterGhosttyStarts() throws {
        _ = TerminalController()
        let home = try XCTUnwrap(getenv("HOME").map { String(cString: $0) })
        unsetenv("HOME")
        defer { setenv("HOME", home, 1) }

        let controller = TerminalController()

        XCTAssertNotNil(
            controller.config, "a controller made after the change must still load its config")
    }
}

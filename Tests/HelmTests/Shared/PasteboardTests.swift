import Foundation
import XCTest

@testable import Helm

/// **Tilde-versus-absolute, pinned in the one place that answers it.**
///
/// helm copies a path from three surfaces — the canvas header (#168), the artifact browser and
/// the workspace bar — and before this they gave two different answers: the browser abbreviated
/// with `~`, the workspace bar did not. A copied path leaves helm for a shell, an agent's
/// context or a tool that never expands a tilde, so the abbreviated form is the one that looks
/// right and then is not a path at all.
///
/// The write itself is untestable here on purpose: `NSPasteboard.general` is the operator's
/// real clipboard and a test has no business clearing it. What is worth holding is the *value*
/// that would be written, which is why the choice is a function rather than an expression at
/// three call sites.
final class PasteboardTests: XCTestCase {
    func testACopiedPathIsAbsoluteRatherThanAbbreviated() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let artifact = home.appendingPathComponent(".prp/helm/plan.md")

        let copied = Pasteboard.path(of: artifact)

        XCTAssertFalse(copied.hasPrefix("~"), "a tilde is only a path where something expands it")
        XCTAssertTrue(copied.hasPrefix("/"))
        XCTAssertEqual(copied, "\(NSHomeDirectory())/.prp/helm/plan.md")
    }

    /// `file://` URLs pick up `.` and `..` segments from whatever composed them, and a path
    /// pasted into a message to another agent is read by a person as often as by a shell.
    func testACopiedPathIsTidiedRatherThanHandedOverRaw() {
        let messy = URL(fileURLWithPath: "/tmp/./helm/../helm/notes.md")

        XCTAssertEqual(Pasteboard.path(of: messy), "/tmp/helm/notes.md")
    }

    /// A trailing slash is display noise on a folder, and the workspace bar copies folders.
    func testAFolderIsCopiedWithoutATrailingSlash() {
        let folder = URL(fileURLWithPath: "/tmp/helm/", isDirectory: true)

        XCTAssertEqual(Pasteboard.path(of: folder), "/tmp/helm")
    }
}

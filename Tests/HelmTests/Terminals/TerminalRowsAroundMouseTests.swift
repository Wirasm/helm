import AppKit
import XCTest

@testable import GhosttyTerminal
@testable import Helm

/// The rows around the mouse, read from a real ghostty surface: what `TerminalStorePath` joins a
/// hard-wrapped path from. A program prints a path split across two rows the way a TUI wraps one,
/// with a newline and no soft-wrap; the mouse rests on the first half.
///
/// Needs a ghostty surface, so it has the keyboard suites' limit: with every display asleep the
/// surface never comes up, and the test says so (`MissingTerminalSurface`).
@MainActor
final class TerminalRowsAroundMouseTests: XCTestCase {
    func testAHardWrappedPathIsReadBackAndJoined() throws {
        let program = WrappedPathPrinter(rows: ["/Users/r/.prp/k/rep", "orts/plan.md` ok"])
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let session = TerminalSession(
            ordinal: 1, workspacePath: WorkspacePath(NSTemporaryDirectory()),
            controller: TerminalSession.makeController(userConfig: nil),
            command: program.command)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.hostView
        defer {
            window.contentView = nil
            window.close()
        }
        let budget: TimeInterval = 5
        guard Eventually.holds(within: budget, { session.status == .running }) else {
            throw MissingTerminalSurface(pane: session.id, waited: budget)
        }
        // A few points in from the top-left corner: the first cell of the first row.
        session.hostView.surface?.sendMousePos(x: 6, y: 6)

        var read: TerminalHoveredRows?
        let printed = Eventually.holds {
            read = session.hostView.rowsAroundMouse(reach: 2)
            return read?.rows.first?.hasPrefix("/Users/r/.prp/k/rep") == true
        }

        XCTAssertTrue(printed, "the program's rows never read back: \(String(describing: read))")
        XCTAssertEqual(read?.hovered, 0)
        XCTAssertEqual(read?.rows.count, 3, "the clicked row and two below it")
        XCTAssertEqual(
            TerminalStorePath.candidates("/Users/r/.prp/k/rep", around: read),
            ["/Users/r/.prp/k/reports/plan.md"])
    }
}

/// Clears the screen, prints `rows` one per line from the top, and then waits. Bounded by its own
/// `sleep` rather than by teardown. Its directory carries the `helm-pty-` prefix and this
/// process's pid, so the keyboard suites' sweep removes it after a crashed run.
private final class WrappedPathPrinter {
    private let directory: URL
    let command: String

    init(rows: [String]) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-pty-\(getpid())-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("print")
        let lines = rows.map { "'\($0)'" }.joined(separator: " ")
        let body = """
            #!/bin/sh
            printf '\\033[H\\033[2J'
            printf '%s\\r\\n' \(lines)
            exec sleep 30
            """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: script.path)
        command = script.path
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

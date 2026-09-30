import AppKit
import GhosttyKit
import XCTest

@testable import GhosttyTerminal
@testable import Helm

/// #337: a program in a pane read the operator's clipboard with `OSC 52 ;c;?`. ghostty's
/// default `clipboard-read = ask` waited on helm's confirmation delegate, which allows
/// everything, so the clipboard went back to the program base64-encoded. helm now runs ghostty
/// with `clipboard-read = deny` (`TerminalSession.sessionOverrides`).
///
/// No test here reads or writes the operator's clipboard: the live one serves the read from a
/// private pasteboard holding a sentinel.
final class ClipboardReadConfigTests: XCTestCase {
    /// Read back from ghostty's parsed config, with no surface, so this runs on CI too. The
    /// operator's own config cannot reopen the read: helm's override lands after it.
    @MainActor
    func testClipboardReadsAreDeniedWhateverTheOperatorsConfigSays() {
        for userConfig in [nil, "clipboard-read = allow"] {
            let controller = TerminalSession.makeController(userConfig: userConfig)
            XCTAssertNil(controller.lastConfigurationIssue)

            var value: UnsafePointer<CChar>?
            let key = "clipboard-read"
            let found = ghostty_config_get(controller.config, &value, key, UInt(key.utf8.count))
            XCTAssertTrue(found, "ghostty does not know \(key)")
            XCTAssertEqual(
                value.map { String(cString: $0) }, "deny",
                "clipboard-read with user config \(userConfig ?? "none")")
        }
    }
}

/// The read itself, end to end: a real ghostty surface with helm's config, a real pty, and a
/// program that asks for the clipboard and records every byte the terminal sends back.
///
/// Needs a ghostty surface, so it has the keyboard suites' limit: with every display asleep
/// the surface never comes up, and the test says so (`MissingTerminalSurface`).
@MainActor
final class ClipboardReadLiveTests: XCTestCase {
    func testAProgramAskingForTheClipboardGetsNothingBack() throws {
        let sentinel = "helm-337-\(UUID().uuidString)"
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)
        TerminalPasteboardContent.readSource = pasteboard
        defer {
            TerminalPasteboardContent.readSource = .general
            pasteboard.releaseGlobally()
        }

        let program = ClipboardAsker()
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
        // The positive control: the program's second query, a primary device attributes
        // request, is answered. Without it, "nothing came back" would also be what a dead pty
        // looks like.
        XCTAssertTrue(
            Eventually.holds { program.received.contains("\u{1b}[?") },
            "the terminal never answered the DA1 query, so the pty path is not live; "
                + "received \(String(reflecting: program.received))")

        // A window that has to elapse: an overshoot only makes the negative more certain.
        let replied = Eventually.holds(within: 3) { program.received.contains("]52;") }
        XCTAssertFalse(
            replied,
            "the terminal answered the clipboard read: \(String(reflecting: program.received))")
        XCTAssertFalse(
            program.received.contains(Data(sentinel.utf8).base64EncodedString()),
            "the clipboard's contents reached the program")
    }
}

/// The program side: asks for the clipboard (`OSC 52 ;c;?`), then for device attributes, and
/// copies everything the terminal sends back into a file. Its directory carries the `helm-pty-`
/// prefix and this process's pid, so the keyboard suites' sweep removes it after a crashed run.
private final class ClipboardAsker {
    private let directory: URL
    let command: String

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-pty-\(getpid())-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("ask")
        // `cat` is bounded by its own watchdog rather than by teardown: `$$` is the shell, and
        // after `exec` it is `cat`.
        let body = """
            #!/bin/sh
            stty raw -echo
            printf '\\033]52;c;?\\033\\\\\\033[c'
            ( sleep 30; kill $$ ) >/dev/null 2>&1 &
            exec cat > '\(directory.path)/received'
            """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: script.path)
        command = script.path
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var received: String {
        let data = (try? Data(contentsOf: directory.appendingPathComponent("received"))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

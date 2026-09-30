import AppKit
import SwiftUI
import XCTest

@testable import Helm

/// The operator's keymap file (#356): every built-in key round-trips through it, it overlays
/// the built-in table, and a bad one changes nothing and says which line.
final class KeymapFileTests: XCTestCase {
    private static let goldenFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/keymap.default.toml")

    private func parse(_ text: String) throws -> KeymapFile { try KeymapFile.parse(text) }

    private func problem(_ text: String) -> KeymapProblem? {
        do {
            _ = try KeymapFile.parse(text).overlay(on: KeyBindings.all)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Every current shortcut works from the file

    /// Each built-in row, rendered and parsed back, is the identical row: chord, `when`,
    /// action, argument, hint and menu. This is what makes the file able to say everything the
    /// Swift table says.
    func testEveryBuiltInRowRoundTripsThroughTheFile() throws {
        let parsed = try parse(KeymapFile.render(KeyBindings.all)).rows.map(\.binding)
        XCTAssertEqual(parsed.count, KeyBindings.all.count)
        for (row, back) in zip(KeyBindings.all, parsed) {
            XCTAssertEqual(back, row, "\(row.chord.spelled) did not survive the file")
        }
    }

    /// `docs/keymap.default.toml` is the rendering of the built-in table, so a new built-in
    /// key fails here until the doc is regenerated. Regenerate with
    /// `HELM_WRITE_KEYMAP_DEFAULT=1 INJECTION_NOGENERICS=1 swift test --filter KeymapFileTests`.
    func testTheDefaultFileInDocsIsTheBuiltInTable() throws {
        let rendered = KeymapFile.render(KeyBindings.all)
        if ProcessInfo.processInfo.environment["HELM_WRITE_KEYMAP_DEFAULT"] == "1" {
            try rendered.write(to: Self.goldenFile, atomically: true, encoding: .utf8)
        }
        let golden = try String(contentsOf: Self.goldenFile, encoding: .utf8)
        XCTAssertEqual(golden, rendered, "docs/keymap.default.toml is stale; see this test's doc")
    }

    /// AC1: the default file copied in whole as the operator's is the built-in table, row for
    /// row — every row replaces its own default in place.
    func testTheDefaultFileAsTheOperatorsChangesNothing() throws {
        let golden = try String(contentsOf: Self.goldenFile, encoding: .utf8)
        XCTAssertEqual(try parse(golden).overlay(on: KeyBindings.all), KeyBindings.all)
    }

    // MARK: - The overlay

    private func match(
        _ characters: String?, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags,
        focus: KeyFocus = .other, in table: [KeyBinding]
    ) -> KeyBinding.Action? {
        KeyBindings.match(
            characters: characters, keyCode: keyCode, modifiers: modifiers,
            focus: focus, in: table)?.action
    }

    func testARowRebindsAKeyInItsPlace() throws {
        let table = try parse(
            """
            [[bind]]
            key = "cmd+d"
            action = "split"
            direction = "down"
            hint = "split"
            """
        ).overlay(on: KeyBindings.all)

        XCTAssertEqual(match("d", .command, in: table), .verb(.split(.down)))
        XCTAssertEqual(table.count, KeyBindings.all.count, "replaced, not added")
        XCTAssertEqual(
            table.firstIndex { $0.chord.spelled == "cmd+d" },
            KeyBindings.all.firstIndex { $0.chord.spelled == "cmd+d" },
            "in the default's place, so the key pop-up keeps its order")
    }

    func testUnbindRemovesABuiltInKeyAndLeavesTheRest() throws {
        let table = try parse(#"unbind = ["cmd+shift+r"]"#).overlay(on: KeyBindings.all)
        XCTAssertNil(match("r", [.command, .shift], in: table))
        XCTAssertEqual(table.count, KeyBindings.all.count - 1)
        XCTAssertEqual(match("n", .command, in: table), .verb(.newTerminal))
    }

    func testANewChordIsAddedAndFires() throws {
        let table = try parse(
            """
            [[bind]]
            key = "cmd+alt+b"
            action = "new-note"
            """
        ).overlay(on: KeyBindings.all)
        XCTAssertEqual(match("b", [.command, .option], in: table), .local(.newNote))
        XCTAssertEqual(table.count, KeyBindings.all.count + 1)
    }

    /// A row in the other half of a split `when` sits beside the default rather than
    /// replacing it: ⌃3 inside a terminal is free, because the built-in ⌃3 only fires outside.
    func testARowInTheOppositeWhenKeepsTheDefault() throws {
        let table = try parse(
            """
            [[bind]]
            key = "ctrl+3"
            when = "terminal"
            action = "new-terminal"
            """
        ).overlay(on: KeyBindings.all)
        XCTAssertEqual(match("3", .control, focus: .terminal, in: table), .verb(.newTerminal))
        XCTAssertEqual(
            match("3", .control, focus: .other, in: table),
            .verb(.activateWorkspace(index: 2)))
    }

    /// The rule `BindingTableTests` holds the built-in table to, held by whatever a file makes
    /// of it: an `anywhere` row over a split pair drops both halves.
    func testTheEffectiveTableNeverClaimsAChordTwice() throws {
        let table = try parse(
            """
            [[bind]]
            key = "ctrl+left"
            action = "new-terminal"
            """
        ).overlay(on: KeyBindings.all)
        for (index, row) in table.enumerated() {
            XCTAssertFalse(
                table[(index + 1)...].contains { $0.collides(with: row) }, row.chord.spelled)
        }
        XCTAssertEqual(
            match(nil, keyCode: 123, .control, focus: .terminal, in: table),
            .verb(.newTerminal))
    }

    // MARK: - The manage key (#498)

    /// `manage` moves the whole layer: every built-in row on ⌘⌥ or ⌘⌥⇧ lands on the new set,
    /// keeping its ⇧, and every other row stays where it was.
    func testTheManageKeyMovesTheWholeLayerAndNothingElse() throws {
        let table = try parse(#"manage = "cmd+ctrl""#).overlay(on: KeyBindings.all)
        XCTAssertEqual(table.count, KeyBindings.all.count)
        XCTAssertEqual(match("j", [.command, .control], in: table), .verb(.stepFocus(.down)))
        XCTAssertEqual(
            match(nil, keyCode: 123, [.command, .control, .shift], in: table),
            .verb(.moveFocused(.left)))
        XCTAssertEqual(
            match("4", [.command, .control], in: table), .verb(.activateWorkspace(index: 3)))
        XCTAssertEqual(match("w", [.command, .control], in: table), .verb(.closeFocused))
        XCTAssertNil(match("j", [.command, .option], in: table), "the old layer is gone")
        XCTAssertEqual(
            match("3", .control, in: table), .verb(.activateWorkspace(index: 2)),
            "⌃3 is not the layer and stays")
        XCTAssertEqual(match("d", .command, in: table), .verb(.split(.right)))
    }

    /// `manage` in a key or an unbind means the file's manage key, not the built-in one.
    func testManageInAChordIsTheFilesManageKey() throws {
        let table = try parse(
            """
            manage = "cmd+ctrl"
            unbind = ["manage+w"]

            [[bind]]
            key = "manage+shift+n"
            action = "new-note"
            """
        ).overlay(on: KeyBindings.all)
        XCTAssertEqual(match("N", [.command, .control, .shift], in: table), .local(.newNote))
        XCTAssertNil(match("w", [.command, .control], in: table))
        XCTAssertEqual(
            try KeyChord(parsing: "manage+shift+h"),
            KeyChord(.character("h"), [.command, .option, .shift]),
            "with no manage field, manage is the built-in ⌘⌥")
    }

    /// The invariant: the manage key never takes a keystroke a terminal types (⌥ types
    /// characters on his layout, ⌃ sends control codes), never includes the layer's own ⇧, and
    /// never lands the layer on a chord another row has.
    func testAManageKeyThatWouldBreakTypingOrCollideIsRefused() {
        for (manage, expected) in [
            ("alt", "must include cmd"),
            ("ctrl", "must include cmd"),
            ("cmd+shift", "cannot include shift"),
            ("cmd+hyper", "'hyper' is not"),
            ("cmd+cmd", "'cmd' twice"),
            ("cmd", "manage cmd puts cmd+"),
        ] {
            let reason = problem("manage = \"\(manage)\"")?.reason ?? "accepted"
            XCTAssertTrue(reason.contains(expected), "\(manage): \(reason)")
        }
        XCTAssertEqual(
            problem(
                """
                [[bind]]
                key = "manage+cmd+x"
                action = "new-terminal"
                """)?.reason, "key 'manage+cmd+x': 'cmd' twice")
    }

    /// A file that does not name the manage key is read against the built-in one, so a file
    /// written before the field existed means what it meant.
    func testAFileWithoutManageIsReadAgainstTheBuiltInKey() throws {
        XCTAssertEqual(try parse("").manage, .builtIn)
        XCTAssertEqual(try parse("").overlay(on: KeyBindings.all), KeyBindings.all)
    }

    // MARK: - Refusals name the line

    func testAnUnknownActionIsRefusedWithItsLine() {
        XCTAssertEqual(
            problem(
                """
                [[bind]]
                key = "cmd+d"
                action = "split"
                direction = "down"

                [[bind]]
                key = "cmd+e"
                action = "open-brwoser"
                """),
            KeymapProblem(line: 6, reason: "unknown action 'open-brwoser'"))
    }

    func testABadChordIsRefused() {
        for (key, reason) in [
            ("cmd+shfit+b", "key 'cmd+shfit+b': 'shfit' is not manage, cmd, ctrl, alt or shift"),
            ("cmd++", "key 'cmd++': write the + key as 'plus'"),
            (
                "cmd+enter",
                "key 'cmd+enter': 'enter' is not one character, plus, an arrow or keycode:N"
            ),
            ("cmd+cmd+b", "key 'cmd+cmd+b': 'cmd' twice"),
        ] {
            XCTAssertEqual(
                problem("[[bind]]\nkey = \"\(key)\"\naction = \"new-terminal\"\n"),
                KeymapProblem(line: 1, reason: reason))
        }
    }

    func testAnArgumentOutOfRangeOrMisplacedIsRefused() {
        let cases: [(String, String)] = [
            ("action = \"show-tab\"\nindex = 0", "'show-tab' index starts at 1, not 0"),
            ("action = \"split\"", "'split' needs direction"),
            ("action = \"split\"\ndirection = \"left\"", "'split' cannot take direction 'left'"),
            ("action = \"new-terminal\"\nindex = 2", "'new-terminal' takes no argument, not index"),
            (
                "action = \"focus\"\ndirection = \"up\"\nindex = 1",
                "'focus' takes only direction, not index"
            ),
            (
                "action = \"font-size\"\nstep = \"bigger\"",
                "'font-size' step is increase, decrease or reset, not 'bigger'"
            ),
        ]
        for (body, reason) in cases {
            XCTAssertEqual(
                problem("[[bind]]\nkey = \"cmd+k\"\n\(body)\n"),
                KeymapProblem(line: 1, reason: reason))
        }
    }

    /// A typo in a field name must not be a row that silently does less than it says.
    func testAnUnknownFieldIsRefused() {
        XCTAssertEqual(
            problem("\n[[bind]]\nkey = \"cmd+k\"\naction = \"new-terminal\"\nhnit = \"x\"\n"),
            KeymapProblem(line: 2, reason: "unknown field 'hnit' in [[bind]]"))
        XCTAssertEqual(
            problem("unbnid = [\"cmd+k\"]\n"),
            KeymapProblem(line: nil, reason: "unknown field 'unbnid'"))
    }

    func testTwoRowsClaimingOneChordAreRefused() {
        XCTAssertEqual(
            problem(
                """
                [[bind]]
                key = "cmd+k"
                action = "new-terminal"

                [[bind]]
                key = "cmd+k"
                when = "terminal"
                action = "new-note"
                """),
            KeymapProblem(line: 5, reason: "cmd+k is already bound on line 1"))
    }

    func testATOMLSyntaxErrorIsRefused() throws {
        let refused = try XCTUnwrap(problem("[[bind]\nkey = \"cmd+k\"\n"))
        XCTAssertTrue(refused.sentence.contains("Line 1"), refused.sentence)
    }

    // MARK: - Drawers

    /// A drawer key names the drawer and, optionally, what an empty one starts with; a bad
    /// surface is refused at load rather than when the key is pressed.
    func testADrawerKeyNamesItsDrawer() throws {
        let rows = try parse(
            """
            [[bind]]
            key = "cmd+shift+j"
            action = "drawer"
            name = "notes"
            surface = "file:/tmp/notes.md"

            [[bind]]
            key = "cmd+shift+k"
            action = "drawer"
            name = "browser"
            """
        ).rows.map(\.binding.action)
        XCTAssertEqual(
            rows,
            [
                .verb(.toggleDrawer(name: "notes", surface: .canvas(path: "/tmp/notes.md"))),
                .verb(.toggleDrawer(name: "browser", surface: nil)),
            ])
        XCTAssertEqual(
            problem(
                "[[bind]]\nkey = \"cmd+k\"\naction = \"drawer\"\nname = \"x\"\nsurface = \"tv\"\n"),
            KeymapProblem(
                line: 1,
                reason:
                    "'drawer' surface is browser, sessions, archon, worktrees or file:<path>, not 'tv'"
            ))
        XCTAssertEqual(
            problem("[[bind]]\nkey = \"cmd+k\"\naction = \"drawer\"\n"),
            KeymapProblem(line: 1, reason: "'drawer' needs name"))
        XCTAssertEqual(
            problem("[[bind]]\nkey = \"cmd+k\"\naction = \"drawer\"\nname = \"Notes\"\n"),
            KeymapProblem(
                line: 1, reason: "'drawer' name 'Notes': a drawer name is 1-32 of [a-z0-9-]"))
    }

    /// A drawer can sit along the bottom of the window (#382); `size` is then its height. An
    /// edge helm cannot draw is refused when the file loads, naming the ones it can.
    func testADrawerCanSitOnTheBottomEdgeAndNoOtherNewOne() throws {
        let file = try parse("[drawer.archon]\nedge = \"bottom\"\nsize = 0.34\n")
        XCTAssertEqual(file.drawers["archon"], DrawerStyle(edge: .bottom, size: 0.34))
        XCTAssertEqual(
            problem("[drawer.x]\nedge = \"top\"\n"),
            KeymapProblem(line: nil, reason: "[drawer.x]: edge is left, right or bottom, not 'top'")
        )
    }

    /// `[drawer.<name>]` sets where a drawer sits; what it leaves out is the drawer's built-in.
    func testADrawerTableOverridesOnlyWhatItSets() throws {
        let file = try parse(
            """
            [drawer.sessions]
            size = 0.4

            [drawer.notes]
            edge = "left"
            """)
        XCTAssertEqual(file.drawers["sessions"], DrawerStyle(edge: .left, size: 0.4))
        XCTAssertEqual(file.drawers["notes"], DrawerStyle(edge: .left, size: 0.5))
        XCTAssertEqual(
            problem("[drawer.x]\nsize = 1.5\n"),
            KeymapProblem(line: nil, reason: "[drawer.x]: size is 0.1 to 0.9, not 1.5"))
        XCTAssertEqual(
            problem("[drawer.x]\nwidth = 0.3\n"),
            KeymapProblem(line: nil, reason: "unknown field 'width' in [drawer.x]"))
        XCTAssertEqual(
            problem("[drawer.Notes]\nsize = 0.3\n"),
            KeymapProblem(
                line: nil, reason: "[drawer.Notes]: a drawer name is 1-32 of [a-z0-9-]"))
    }

    /// A key can run a recipe from the operator's bench justfile.
    func testAJustKeyNamesItsRecipe() throws {
        let rows = try parse(
            "[[bind]]\nkey = \"cmd+alt+j\"\naction = \"just\"\nrecipe = \"day\"\n"
        ).rows.map(\.binding.action)
        XCTAssertEqual(rows, [.just(recipe: "day")])
        XCTAssertEqual(
            problem("[[bind]]\nkey = \"cmd+k\"\naction = \"just\"\n"),
            KeymapProblem(line: 1, reason: "'just' needs recipe"))
        XCTAssertEqual(
            try parse(
                KeymapFile.render([KeyBinding(.character("j"), .command, .just(recipe: "day"))])
            )
            .rows.map(\.binding.action),
            [.just(recipe: "day")], "a just row round-trips")
    }

    // MARK: - Chords

    func testChordsSpellEveryTriggerKind() throws {
        for (text, chord) in [
            ("cmd+shift+b", KeyChord(.character("b"), [.command, .shift])),
            ("cmd+plus", KeyChord(.character("+"), .command)),
            (
                "cmd+ctrl+alt+shift+left",
                KeyChord(.keyCode(123), [.command, .control, .option, .shift])
            ),
            ("keycode:53", KeyChord(.keyCode(53), [])),
        ] {
            XCTAssertEqual(try KeyChord(parsing: text), chord, text)
            XCTAssertEqual(chord.spelled, text)
        }
        XCTAssertEqual(
            try KeyChord(parsing: "shift+cmd+B"), KeyChord(.character("b"), [.command, .shift]),
            "modifiers in any order, and a letter in either case, as match folds case")
    }
}

/// The table in force: the built-in rows until a file says otherwise, and never fewer keys
/// because of a bad file.
@MainActor
final class KeymapTests: XCTestCase {
    private let rebind = """
        [[bind]]
        key = "cmd+d"
        action = "new-terminal"
        """

    private func fires(
        _ keymap: Keymap, _ characters: String, _ modifiers: NSEvent.ModifierFlags
    )
        -> KeyBinding.Action?
    {
        KeyBindings.match(
            characters: characters, keyCode: 0, modifiers: modifiers, focus: .other,
            in: keymap.table)?.action
    }

    func testABadFileKeepsTheLastGoodTableAndSaysWhy() {
        let keymap = Keymap(file: nil)
        keymap.apply(.text(rebind))
        XCTAssertEqual(fires(keymap, "d", .command), .verb(.newTerminal))

        keymap.apply(.text("[[bind]]\nkey = \"cmd+d\"\naction = \"nope\"\n"))
        XCTAssertEqual(
            fires(keymap, "d", .command), .verb(.newTerminal), "the last good table, not defaults")
        XCTAssertEqual(keymap.problem, KeymapProblem(line: 1, reason: "unknown action 'nope'"))

        keymap.apply(.text(rebind + "\nhint = \"t\"\n"))
        XCTAssertNil(keymap.problem, "a good save clears it")
    }

    /// On the first read there is no last good file, so a bad one leaves the built-in table.
    func testABadFirstFileLeavesTheBuiltInKeys() {
        let keymap = Keymap(file: nil)
        keymap.apply(.unreadable("cannot be read: permission denied"))
        XCTAssertEqual(keymap.table, KeyBindings.all)
        XCTAssertEqual(
            keymap.problem?.sentence, "keymap.toml: cannot be read: permission denied")
    }

    func testAMissingFileIsTheBuiltInTable() {
        let keymap = Keymap(file: nil)
        keymap.apply(.text(rebind))
        keymap.apply(.absent)
        XCTAssertEqual(keymap.table, KeyBindings.all)
        XCTAssertNil(keymap.problem)
    }

    func testReadTellsAMissingFileFromAnUnreadableOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymap-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("keymap.toml")

        XCTAssertEqual(Keymap.read(file), .absent)
        try Data([0xFF, 0xFE]).write(to: file)
        XCTAssertEqual(Keymap.read(file), .unreadable("is not UTF-8"))
        try "x = 1".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Keymap.read(file), .text("x = 1"))
    }

    /// M5c: the keymap is helm's own file now, not the bench root's. A keymap at the old path
    /// comes along once; one already at the new path is never replaced, and the old one is left
    /// where it is.
    func testAKeymapAtTheOldPathIsMovedOnceAndNeverOverAnExistingOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymap-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("bench/rules/keymap.toml")
        let new = dir.appendingPathComponent("helm/bench/keymap.toml")

        Keymap.moveOnce(from: old, to: new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "nothing to move")

        try FileManager.default.createDirectory(
            at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "manage = \"cmd+alt\"\n".write(to: old, atomically: true, encoding: .utf8)
        Keymap.moveOnce(from: old, to: new)
        XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "manage = \"cmd+alt\"\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "moved, not copied")

        try "stale".write(to: old, atomically: true, encoding: .utf8)
        Keymap.moveOnce(from: old, to: new)
        XCTAssertEqual(
            try String(contentsOf: new, encoding: .utf8), "manage = \"cmd+alt\"\n",
            "the operator's current keys win")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    /// The live half: a file written while helm runs is in force without a relaunch. It waits
    /// for the change to arrive inside a generous deadline, so a slow machine only makes it
    /// slower, never red.
    func testAFileWrittenWhileWatchingIsAdopted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymap-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("keymap.toml")
        let keymap = Keymap(file: file)
        let watching = Task { await keymap.watch(every: .milliseconds(20)) }
        defer { watching.cancel() }

        try rebind.write(to: file, atomically: false, encoding: .utf8)
        let deadline = Date().addingTimeInterval(10)
        while fires(keymap, "d", .command) != .verb(.newTerminal), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(fires(keymap, "d", .command), .verb(.newTerminal))
    }
}

extension KeymapFileTests {
    /// `browser` and `away-from-browser` are opposite halves too (#542): a row for ⌘1 in the
    /// browser replaces only the browser's ⌘1, and the slot's ⌘1 stays.
    func testABrowserRowReplacesOnlyTheBrowsersHalf() throws {
        let table = try parse(
            """
            [[bind]]
            key = "cmd+1"
            when = "browser"
            action = "browser-reload"
            """
        ).overlay(on: KeyBindings.all)
        XCTAssertEqual(match("1", .command, focus: .browser, in: table), .local(.browser(.reload)))
        XCTAssertEqual(match("1", .command, in: table), .verb(.showTab(index: 0)))
        XCTAssertEqual(table.count, KeyBindings.all.count)
    }
}

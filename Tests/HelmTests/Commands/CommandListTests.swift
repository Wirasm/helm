import HelmWire
import XCTest

@testable import Helm

/// The command palette's lines (#500): derived from the key table, benchd's document and the
/// bench justfile, and run through the same doors a key uses.
final class CommandListTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private let slotA = UUID(), slotB = UUID(), slotC = UUID()

    /// Two workspaces: `/w/app` on screen with two slots, `/w/api` parked with one.
    private var document: BenchDocument {
        func column(
            _ slot: UUID, _ pane: UUID, _ surface: Surface, _ name: PaneName = .unnamed
        )
            -> BenchDocument.Column
        {
            BenchDocument.Column(
                id: UUID(),
                slots: [
                    BenchDocument.Slot(
                        id: slot, panes: [.init(id: pane, surface: surface, name: name)],
                        selected: pane, height: 1)
                ], width: 1)
        }
        return BenchDocument(
            workspaces: [
                .init(
                    path: "/w/app",
                    bench: .init(
                        columns: [
                            column(slotA, a, .terminal(agent: nil)),
                            column(slotB, b, .canvas(path: "/w/app/plan.md")),
                        ], focusedSlot: slotA)),
                .init(
                    path: "/w/api",
                    bench: .init(
                        columns: [column(slotC, c, .terminal(agent: nil), .chosen("codex"))],
                        focusedSlot: slotC)),
            ], active: "/w/app")
    }

    private func list(
        _ table: [KeyBinding] = KeyBindings.all, recipes: [String] = []
    ) -> [Command] {
        CommandList.of(table: table, document: document, recipes: recipes)
    }

    private func line(_ title: String, in commands: [Command]) -> Command? {
        commands.first { $0.title == title }
    }

    /// Every distinct action in the table is a line, titled by its menu item and showing its
    /// key, and runs the row's own action: the palette cannot do what no key does, or do it
    /// differently.
    func testEveryActionInTheTableIsALineThatRunsItsOwnAction() {
        let commands = list()
        XCTAssertEqual(
            line("Split Right", in: commands),
            Command(title: "Split Right", keys: "⌘D", run: .action(.verb(.split(.right)))))
        XCTAssertEqual(line("Focus Left", in: commands)?.keys, "⌥⌘←")
        XCTAssertEqual(
            line("Next Workspace", in: commands)?.run, .action(.verb(.cycleWorkspace(delta: 1))),
            "a row with no menu item is titled by its action")
        XCTAssertEqual(
            commands.filter { $0.run == .action(.verb(.stepFocus(.left))) }.count, 1,
            "the arrow and the letter for one action are one line")
        XCTAssertNil(line("Command Palette", in: commands), "the palette does not list itself")
        XCTAssertNil(line("Show Tab 1", in: commands), "tabs are listed as the panes they are")
    }

    /// A key the operator's file adds is a line with no code change.
    func testAnOperatorKeyIsALine() throws {
        let table = try KeymapFile.parse(
            """
            [[bind]]
            key = "cmd+shift+j"
            action = "just"
            recipe = "deploy"
            menu = "Deploy"
            """
        ).overlay(on: KeyBindings.all)
        XCTAssertEqual(
            line("Deploy", in: list(table)),
            Command(title: "Deploy", keys: "⇧⌘J", run: .action(.just(recipe: "deploy"))))
    }

    /// Every workspace in the document, named, with the key that selects it from anywhere: ⌥⌘2
    /// rather than ⌃2, which a focused shell keeps.
    func testEveryWorkspaceIsALine() {
        XCTAssertEqual(
            line("Workspace api", in: list()),
            Command(
                title: "Workspace api", keys: "⌥⌘2",
                run: .verbs([.workspaceActivate(path: "/w/api")])))
    }

    /// Every pane in every workspace: going to one on screen shows it and moves the keyboard
    /// to its slot; going to one in a parked workspace activates that workspace first.
    func testEveryPaneIsALineThatGoesThere() {
        let commands = list()
        XCTAssertEqual(
            line("plan.md", in: commands),
            Command(title: "plan.md", run: .verbs([.paneShow(b), .focusSlot(slotB)])),
            "a pane in the workspace on screen needs no workspace beside it")
        XCTAssertEqual(
            line("codex", in: commands),
            Command(
                title: "codex", detail: "api",
                run: .verbs([
                    .workspaceActivate(path: "/w/api"), .paneShow(c), .focusSlot(slotC),
                ])))
    }

    /// A pane is named by its name, else what its tab shows. A terminal with no live session
    /// (its workspace not drawn since launch) is its agent, else `terminal N`, numbered among
    /// only those: two plain shells in a parked workspace are two different lines, and none can
    /// print the `shell N` a live tab numbers app-wide.
    func testAPaneWithNoLiveSessionIsStillTellableApart() {
        func terminal(_ agent: BenchDocument.Agent? = nil) -> BenchDocument.Pane {
            .init(id: UUID(), surface: .terminal(agent: agent))
        }
        let live = terminal()
        let claude = terminal(.init(command: "claude", session: "s", cwd: "/w"))
        let first = terminal()
        let second = terminal()
        let slot = UUID()
        let parked = BenchDocument(
            workspaces: [
                .init(
                    path: "/w/parked",
                    bench: .init(
                        columns: [
                            .init(
                                id: UUID(),
                                slots: [
                                    .init(
                                        id: slot, panes: [live, claude, first, second],
                                        selected: first.id, height: 1)
                                ], width: 1)
                        ], focusedSlot: slot))
            ], active: nil)
        let titles = CommandList.of(table: [], document: parked, recipes: []) {
            $0.id == live.id ? "shell 2" : nil
        }
        .filter { $0.detail == "parked" }.map(\.title)
        XCTAssertEqual(titles, ["shell 2", "claude", "terminal 1", "terminal 2"])
        XCTAssertEqual(Set(titles).count, titles.count, "no two lines read the same")
        XCTAssertEqual(
            CommandList.title(
                of: .init(
                    id: UUID(), surface: .canvas(path: "/w/plan.md"), name: .chosen("the plan")),
                live: nil),
            "the plan")
    }

    /// Each recipe in the bench justfile is a line; one a key already runs is not listed twice.
    func testRecipesAreLinesAndABoundOneIsListedOnce() {
        let table =
            KeyBindings.all + [
                KeyBinding(.character("j"), [.command, .shift], .just(recipe: "deploy"))
            ]
        let commands = list(table, recipes: ["deploy", "day"])
        XCTAssertEqual(
            line("just day", in: commands),
            Command(title: "just day", run: .action(.just(recipe: "day"))))
        XCTAssertEqual(commands.filter { $0.run == .action(.just(recipe: "deploy")) }.count, 1)
    }

    /// With benchd not answering there is no document: the table's lines are still there.
    func testWithNoDocumentTheKeysAreStillThere() {
        let commands = CommandList.of(table: KeyBindings.all, document: nil, recipes: [])
        XCTAssertNotNil(line("New Terminal", in: commands))
        XCTAssertFalse(commands.contains { $0.title.hasPrefix("Workspace ") })
    }

    // MARK: - Searching

    func testAQueryFindsItsCharactersInOrderAndRanksWordStartsFirst() {
        XCTAssertNotNil(FuzzyMatch.score("nt", in: "New Terminal"))
        XCTAssertNil(FuzzyMatch.score("tn", in: "Net"))
        let ranked = FuzzyMatch.rank(
            ["Increase Font Size", "New Terminal", "Split Right"], by: "nt"
        ) { $0 }
        XCTAssertEqual(ranked, ["New Terminal", "Increase Font Size"])
        XCTAssertEqual(
            FuzzyMatch.rank(["b", "a"], by: "") { $0 }, ["b", "a"],
            "an empty query keeps every line in order")
    }

    @MainActor
    func testThePickStaysInsideTheList() {
        let palette = CommandPalette(listRecipes: { [] })
        palette.open()
        palette.move(-1, count: 3)
        XCTAssertEqual(palette.selection, 0)
        palette.move(5, count: 3)
        XCTAssertEqual(palette.selection, 2)
        palette.query = "x"
        XCTAssertEqual(palette.selection, 0, "a new query starts at the best match")
        palette.toggle()
        XCTAssertFalse(palette.isOpen)
    }

    /// Every time the palette opens it asks benchd for the recipes afresh, so one added to the
    /// justfile is offered the next time; when benchd cannot answer, the rest still works.
    @MainActor
    func testOpeningAsksForTheRecipesAfresh() async throws {
        let answers = Answers([["day"], ["day", "deploy"]])
        let palette = CommandPalette(listRecipes: { try answers.next() })
        palette.open()
        try await until { palette.recipes == ["day"] }
        palette.close()
        palette.open()
        try await until { palette.recipes == ["day", "deploy"] }

        // A slow answer to an earlier open does not overwrite the latest open's list.
        let gate = DispatchSemaphore(value: 0)
        let calls = Answers([["old"], ["new"]])
        let slow = CommandPalette(listRecipes: {
            let answer = try calls.next()
            if answer == ["old"] { gate.wait() }
            return answer
        })
        slow.open()
        try await until { calls.taken == 1 }  // the first open's answer is on its way, held
        slow.close()
        slow.open()
        try await until { slow.recipes == ["new"] }
        gate.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(slow.recipes, ["new"], "the earlier open's answer came last and was dropped")

        let broken = CommandPalette(listRecipes: { throw JustRuns.Refused(description: "gone") })
        broken.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(broken.recipes, [])
        XCTAssertTrue(broken.isOpen)
    }

    @MainActor
    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done())
    }
}

/// Canned `just/list` answers, one per call.
private final class Answers: @unchecked Sendable {
    private var queue: [[String]]
    private let lock = NSLock()
    init(_ queue: [[String]]) { self.queue = queue }
    private var count = 0
    var taken: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func next() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return queue.removeFirst()
    }
}

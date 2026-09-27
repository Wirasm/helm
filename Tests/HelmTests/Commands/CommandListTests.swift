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
        CommandList.of(table: table, document: document, recipes: recipes) { pane in
            pane.name.text ?? (pane.surface == .terminal(agent: nil) ? "shell" : "plan.md")
        }
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
            Command(
                title: "plan.md", detail: "app", run: .verbs([.paneShow(b), .focusSlot(slotB)])))
        XCTAssertEqual(
            line("codex", in: commands),
            Command(
                title: "codex", detail: "api",
                run: .verbs([
                    .workspaceActivate(path: "/w/api"), .paneShow(c), .focusSlot(slotC),
                ])))
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
        let commands = CommandList.of(
            table: KeyBindings.all, document: nil, recipes: [], paneTitle: { _ in "" })
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
        let palette = CommandPalette()
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
}

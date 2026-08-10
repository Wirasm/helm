import HelmWire
import XCTest

@testable import Helm

/// The value a pane's name is, and the two things about it that are not obvious (#313): what helm
/// calls a pane it opened for an agent, and what happens to a bench written before any of this
/// existed.
final class PaneNameTests: XCTestCase {

    // MARK: - What helm calls a spawned pane

    private func spawn(command: String = "claude", cwd: String) -> AcceptedSpawnRequest {
        AcceptedSpawnRequest(
            id: RequestID(validating: "s")!, cwd: cwd, command: command, args: [], prompt: nil)
    }

    func testASpawnedPaneIsNamedForItsAgentAndItsTree() {
        // The fix for #313's concrete trigger. helm wrote the request, so it needs nothing from
        // the agent to say something better than the OSC title the agent is about to set.
        XCTAssertEqual(
            PaneName.derived(for: spawn(cwd: "/Users/rasmus/Projects/mine/sild/helm")).text,
            "claude · helm")
        XCTAssertEqual(
            PaneName.derived(
                for: spawn(command: "codex", cwd: "/x/.worktrees/issue-313-name-a-pane")
            ).text,
            "codex · issue-313-name-a-pane")
    }

    func testTheDerivedNameIsDerivedRatherThanChosen() {
        // Load-bearing, and the whole reason `PaneName` is not a `String?`: `SpoolNamePolicy` lets
        // an agent replace this without claiming the operator asked. A `.chosen` here would refuse
        // the agent helm had just spawned when it named its own pane.
        guard case .derived = PaneName.derived(for: spawn(cwd: "/tmp")) else {
            return XCTFail("helm's own label must never read as somebody's choice")
        }
    }

    func testACwdWithNoUsefulBasenameFallsBackToTheAgentAlone() {
        // `lastPathComponent` answers "/" for the root and "" for a trailing slash. A bare
        // `claude` is a worse name than a good one and a far better one than `claude · /`.
        XCTAssertEqual(PaneName.derived(for: spawn(cwd: "/")).text, "claude")
        XCTAssertEqual(PaneName.derived(for: spawn(cwd: "")).text, "claude")
    }

    // MARK: - What survives a restart

    private func roundTrip(_ pane: Pane) throws -> Pane {
        try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
    }

    func testANameSurvivesTheRestartThatThePaneSurvives() throws {
        // #313 asks for this by name: a name lost on relaunch would be worse than no name.
        let pane = Pane(id: UUID(), content: .terminal(face: .terminal), name: .chosen("the plan"))
        XCTAssertEqual(try roundTrip(pane).name, .chosen("the plan"))

        let derived = Pane(
            id: UUID(), content: .canvas(.empty), name: .derived("claude · helm"))
        XCTAssertEqual(
            try roundTrip(derived).name, .derived("claude · helm"),
            "and the provenance travels with it, or the ownership rule means something different "
                + "after a relaunch than it did before one")
    }

    func testABenchWrittenBeforeAnyOfThisKeepsItsPanes() throws {
        // **The failure this decoder exists to avoid, and it is not a lost name.** `Pane`'s
        // synthesized decoder would have thrown on the missing key, and `Slot.init(from:)`
        // deliberately SKIPS a pane it cannot read — so the first launch after upgrade would have
        // dropped every pane in every persisted workspace to save a word on a tab.
        let old = Data(
            #"{"id":"6E33D1F2-4A3E-4D64-9E0B-9C1F4A2B1D77","content":{"kind":"terminal"}}"#.utf8)
        let pane = try JSONDecoder().decode(Pane.self, from: old)
        XCTAssertEqual(pane.name, .unnamed)
        guard case .terminal = pane.content else { return XCTFail("the pane itself must survive") }
    }

    func testAnUnnamedPaneWritesNothingNewAtAll() throws {
        // So a bench nobody has named encodes byte-identically to what every build before #313
        // produced — which is what makes two helms of different vintages able to share a machine,
        // the normal state here.
        let encoded = try JSONEncoder().encode(
            Pane(id: UUID(), content: .terminal(face: .terminal)))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["name"])
    }

    func testANameShapeThisBuildDoesNotUnderstandCostsTheNameAndNotThePane() throws {
        // The same trade `Pane.Content` makes for a malformed `agent`: the pane matters and the
        // name is chrome, so a future provenance read by an older helm degrades to `.unnamed`
        // rather than taking a terminal down with it.
        let future = Data(
            #"""
            {"id":"6E33D1F2-4A3E-4D64-9E0B-9C1F4A2B1D77","content":{"kind":"terminal"},\#
            "name":{"source":"conjured","text":"whatever"}}
            """#.utf8)
        let pane = try JSONDecoder().decode(Pane.self, from: future)
        XCTAssertEqual(pane.name, .unnamed)
        guard case .terminal = pane.content else { return XCTFail("the pane itself must survive") }
    }
}

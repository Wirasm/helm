import HelmWire
import XCTest

@testable import Helm

/// The value a pane's name is (#313), and what happens to a bench written before names existed.
/// What benchd calls a spawned agent's pane is pinned by the daemon's conformance suite.
final class PaneNameTests: XCTestCase {

    // MARK: - What survives a restart

    private func roundTrip(_ pane: Pane) throws -> Pane {
        try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
    }

    func testANameSurvivesTheRestartThatThePaneSurvives() throws {
        // #313 asks for this by name: a name lost on relaunch would be worse than no name.
        let pane = Pane(id: UUID(), content: .terminal(), name: .chosen("the plan"))
        XCTAssertEqual(try roundTrip(pane).name, .chosen("the plan"))

        let derived = Pane(
            id: UUID(), content: .canvas(.file("/tmp/plan.md")), name: .derived("claude · helm"))
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
            Pane(id: UUID(), content: .terminal()))
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

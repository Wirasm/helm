import Foundation
import HelmWire
import XCTest

@testable import PocketKit

/// Home's sections (operator, 2026-10-03): one per workspace, the running sessions in it with the
/// orchestrators first, the finished ones behind a disclosure, the workspaces that need him first.
final class PocketSectionsTests: XCTestCase {
    private func row(
        _ id: String, _ state: BenchSessionRow.State, cwd: String = "/w/helm", at ms: UInt64 = 0,
        spawner: BenchSpawner? = nil, branch: String? = nil, model: String? = nil,
        handle: String? = nil
    ) -> BenchSessionRow {
        BenchSessionRow(
            harness: "claude", id: id, branch: branch, model: model, handle: handle, cwd: cwd,
            state: state, open: .benchAttach(session: id), updatedAtMs: ms, spawner: spawner)
    }

    private func running(_ activity: String = "busy") -> BenchSessionRow.State {
        .running(activity: activity, detail: nil)
    }

    /// A section holds its running sessions, orchestrators first, and its finished ones apart,
    /// newest first and capped, counting what the cap left out.
    func testASectionIsItsRunningSessionsOrchestratorsFirstAndTheFinishedApart() throws {
        let finished = (0..<14).map { row("f\($0)", .finished(atMs: UInt64(100 + $0))) }
        let sessions = [
            "/w/helm": [
                row("worker", running(), at: 9), row("lead", running(), spawner: .operator),
            ]
                + finished
        ]
        let section = try XCTUnwrap(
            PocketHome.sections(workspaces: ["/w/helm"], sessions: sessions, query: "").first)
        XCTAssertEqual(section.running.map(\.id), ["lead", "worker"])
        XCTAssertEqual(section.finished.map(\.id), (4..<14).reversed().map { "f\($0)" })
        XCTAssertEqual(section.finishedCount, 14)
    }

    /// Workspaces that need him come first, then the ones with something running, each most
    /// recently active first: one whose sessions all finished is last, however recently.
    func testSectionsNeedingHimComeFirstThenTheMostRecentlyActive() {
        let sessions = [
            "/w/quiet": [row("q", running(), at: 900)],
            "/w/asking": [row("a", running("waiting"), at: 10)],
            "/w/old": [row("o", running(), at: 50)],
            "/w/empty": [row("gone", .finished(atMs: 1000))],
        ]
        let order = PocketHome.sections(
            workspaces: ["/w/old", "/w/empty", "/w/quiet", "/w/asking"], sessions: sessions,
            query: ""
        ).map(\.path)
        XCTAssertEqual(order, ["/w/asking", "/w/quiet", "/w/old", "/w/empty"])
    }

    /// "Needs him" is about what the section shows: a session waiting with no screen to open (a
    /// background job) does not put ● on a section that lists nothing to tap.
    func testASectionNeedsHimOnlyForARowItShows() throws {
        var job = row("job", running("waiting"))
        job.open = .claudeAttach(job: "j")
        let section = try XCTUnwrap(
            PocketHome.sections(workspaces: ["/w/bg"], sessions: ["/w/bg": [job]], query: "")
                .first)
        XCTAssertTrue(section.running.isEmpty)
        XCTAssertFalse(section.needsHim)
    }

    /// The search keeps the sessions whose name, handle, branch or model has the words, running or
    /// finished, and drops the sections left with none.
    func testSearchFiltersByNameBranchOrModel() {
        let sessions = [
            "/w/helm": [
                row("a", running(), branch: "feat/pocket-usable"),
                row("b", running(), model: "claude-opus-5-5"),
                row("c", .finished(atMs: 1), handle: "pocket-old"),
            ],
            "/w/prp": [row("d", running(), handle: "prp-lead")],
        ]
        let sections = PocketHome.sections(
            workspaces: ["/w/helm", "/w/prp"], sessions: sessions, query: "POCKET")
        XCTAssertEqual(sections.map(\.path), ["/w/helm"])
        XCTAssertEqual(sections.first?.running.map(\.id), ["a"])
        XCTAssertEqual(sections.first?.finished.map(\.id), ["c"])
        XCTAssertEqual(
            PocketHome.sections(workspaces: ["/w/helm"], sessions: sessions, query: "opus")
                .first?.running.map(\.id), ["b"])
    }
}

import XCTest

@testable import Helm

/// Decoding tests against payloads **captured verbatim from a running engine**, not
/// hand-written to match the Swift types.
///
/// That direction matters. A fixture written from the type will keep passing after the wire
/// changes underneath it, which is the failure these tests exist to prevent — helm's entire
/// backend contract is this JSON, and a field quietly renamed engine-side should break a
/// test here rather than surface as an empty row in the UI.
///
/// Captured from kild @ 60404be (the agent-primitive merge).
final class KildWireTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Kild, costly half

    /// `GET /api/kilds/status` — identity plus the git and cost halves.
    private let statusJSON = """
        {
          "id": "840be0b8-1226-4f0d-9d5d-b137e175c442",
          "name": "helm",
          "cwd": "/Users/rasmus/Projects/mine/sild/helm",
          "base": "development",
          "agents": [
            {
              "handle": "agent",
              "ownership": "owned",
              "persona": "general",
              "idle": true,
              "piSessionId": "019fa823-9737-7b82-ab6f-b62335ec7fb8",
              "piSessionFile": "/Users/rasmus/.pi/agent/sessions/x.jsonl",
              "tokens": 114680,
              "cost": 0.22466100000000003
            },
            {
              "handle": "rewrite-context",
              "ownership": "owned",
              "persona": "codebase-explorer",
              "model": "openai-codex/gpt-5.6-terra",
              "invitedBy": "agent",
              "idle": true
            }
          ],
          "git": {
            "path": "/Users/rasmus/Projects/mine/sild/helm",
            "branch": "development",
            "base": "development",
            "ahead": 0,
            "behind": 0,
            "dirty": true,
            "uncommittedFiles": 3,
            "changedFiles": [],
            "conflictsWithBase": false
          },
          "totals": { "tokens": 457406, "cost": 0.5812125 }
        }
        """

    func testDecodesTheCostlyListing() throws {
        let kild = try decode(Kild.self, statusJSON)
        XCTAssertEqual(kild.name, "helm")
        XCTAssertEqual(kild.base, "development")
        XCTAssertEqual(kild.agents.count, 2)
        XCTAssertEqual(kild.totals?.tokens, 457_406)
        XCTAssertFalse(kild.isOrphan)
    }

    /// The engine sends an integer count here despite the plural name. Decoding it as a
    /// collection would fail at runtime on every live kild.
    func testUncommittedFilesIsACountNotAList() throws {
        let kild = try decode(Kild.self, statusJSON)
        XCTAssertEqual(kild.git?.uncommittedFiles, 3)
    }

    /// An empty `changedFiles` is meaningfully different from an absent one: present-and-
    /// empty means "measured, nothing changed", absent means "not measured". Collision
    /// derivation must not treat them alike.
    func testEmptyChangedFilesDecodesAsEmptyNotNil() throws {
        let kild = try decode(Kild.self, statusJSON)
        XCTAssertEqual(kild.git?.changedFiles, [])
        XCTAssertNotNil(kild.git?.changedFiles)
    }

    func testAgentCarriesTheSpawnEdge() throws {
        let kild = try decode(Kild.self, statusJSON)
        XCTAssertNil(kild.agents[0].invitedBy, "the creator's initial roster has no inviter")
        XCTAssertEqual(kild.agents[1].invitedBy, "agent")
    }

    /// pi handles arrive only on the costly call, and only for owned agents — they are what
    /// a fork-to-terminal would run against.
    func testOwnedAgentCarriesPiSessionHandles() throws {
        let kild = try decode(Kild.self, statusJSON)
        XCTAssertEqual(kild.agents[0].piSessionId, "019fa823-9737-7b82-ab6f-b62335ec7fb8")
        XCTAssertNotNil(kild.agents[0].piSessionFile)
    }

    // MARK: - Kild, cheap half

    /// `GET /api/kilds` — an orphan: a `kild/*` worktree on disk whose record is gone.
    /// It is addressed by worktree name because it has no other id, and carries no git,
    /// no totals and no agents.
    private let orphanJSON = """
        {
          "id": "live-demo",
          "name": "live-demo",
          "cwd": "/Users/rasmus/Projects/mine/sild/kild/engine/.kild-spike/sample-repo",
          "worktree": "live-demo",
          "orphan": true,
          "agents": []
        }
        """

    func testDecodesAnOrphan() throws {
        let kild = try decode(Kild.self, orphanJSON)
        XCTAssertTrue(kild.isOrphan)
        XCTAssertEqual(kild.worktree, "live-demo")
        XCTAssertTrue(kild.agents.isEmpty)
        XCTAssertNil(kild.base, "an orphan has no record, so nothing stated its base")
        XCTAssertNil(kild.git, "the cheap listing carries no git")
    }

    /// Absent `orphan` means a normal kild. The engine omits the field rather than sending
    /// false, so the optional must not be read as "unknown".
    func testAbsentOrphanFlagMeansNotAnOrphan() throws {
        let kild = try decode(Kild.self, statusJSON)
        XCTAssertNil(kild.orphan)
        XCTAssertFalse(kild.isOrphan)
    }

    // MARK: - Agents

    func testOwnershipDecodesBothCases() throws {
        let owned = try decode(Agent.self, #"{"handle":"a","ownership":"owned"}"#)
        let attached = try decode(Agent.self, #"{"handle":"b","ownership":"attached"}"#)
        XCTAssertEqual(owned.ownership, .owned)
        XCTAssertEqual(attached.ownership, .attached)
    }

    /// The engine resolves absent ownership to `owned` before serialising, so the field is
    /// always present. If that ever regresses, decoding should fail loudly here rather than
    /// have helm silently guess — an archive once shipped agents with no ownership at all.
    func testMissingOwnershipFailsRatherThanDefaulting() {
        XCTAssertThrowsError(try decode(Agent.self, #"{"handle":"a"}"#))
    }

    // MARK: - Archive

    /// `GET /api/kilds/archive` — carries **no log**, by design.
    private let archivedJSON = """
        {
          "id": "c8971dd5-35ea-4a39-9886-46618c86ed4b",
          "name": "helm",
          "agents": [{ "handle": "claude", "ownership": "attached" }],
          "cwd": "/Users/rasmus/Projects/mine/sild/helm",
          "base": "development",
          "endedAt": 1785180000000
        }
        """

    func testDecodesAnArchivedKild() throws {
        let archived = try decode(ArchivedKild.self, archivedJSON)
        XCTAssertEqual(archived.name, "helm")
        XCTAssertEqual(archived.endedAt, 1_785_180_000_000)
    }

    /// Archives written before `endedAt` existed have no clock. Deliberately no fallback:
    /// a synthesised timestamp is a guess wearing the costume of a fact, and the archive
    /// lost its only other ordering signal when the log was removed from the listing.
    func testArchiveWithoutEndedAtDecodesRatherThanFailing() throws {
        let archived = try decode(
            ArchivedKild.self,
            #"{"id":"x","name":"old","agents":[]}"#)
        XCTAssertNil(archived.endedAt)
    }

    // MARK: - Messages

    private let messageJSON = """
        {
          "id": "m-1",
          "kildId": "840be0b8-1226-4f0d-9d5d-b137e175c442",
          "from": "kild",
          "to": ["claude"],
          "text": "attribution bug — and this message is the proof of it",
          "ts": 1785180000000,
          "seq": 8
        }
        """

    func testDecodesAMessage() throws {
        let message = try decode(Message.self, messageJSON)
        XCTAssertEqual(message.from, "kild")
        XCTAssertEqual(message.to, ["claude"])
        XCTAssertEqual(message.seq, 8)
    }

    /// `seq` is the cursor and `ts` is not. Both are present; only one is monotonic, and
    /// paging on the wrong one silently drops or repeats messages when a clock moves.
    func testSeqAndTimestampAreDistinctFields() throws {
        let message = try decode(Message.self, messageJSON)
        XCTAssertEqual(message.seq, 8)
        XCTAssertEqual(message.ts, 1_785_180_000_000)
    }

    // MARK: - Landing

    /// `GET /api/kilds/:id/land`, captured verbatim from a running engine.
    ///
    /// This test exists because its absence cost a whole feature. `LandReport` was written
    /// from an API sketch rather than a capture and shared **no field names** with the wire
    /// — no `ok`, no `ahead`, no `conflictsWithBase`. Since `ok` was required and never
    /// sent, every land call threw `keyNotFound`, dry run included. The route returns 200
    /// for landable and blocked alike, so there was no path on which it worked.
    ///
    /// The client tests did not catch it because they stubbed JSON matching the Swift type.
    /// A fixture written from the type keeps passing no matter what the engine does, which
    /// is exactly what this file's header warns about — and then this type did it anyway.
    private let landJSON = """
        {
          "base": "development",
          "branch": "development",
          "commits": [],
          "files": [],
          "collides": [],
          "wouldMerge": false,
          "merged": false,
          "error": "the kild ran on development itself — there is no branch to land",
          "dryRun": true
        }
        """

    func testDecodesARealLandReport() throws {
        let report = try decode(LandReport.self, landJSON)
        XCTAssertEqual(report.base, "development")
        XCTAssertFalse(report.wouldMerge)
        XCTAssertFalse(report.merged)
        XCTAssertEqual(report.dryRun, true)
        XCTAssertEqual(
            report.error, "the kild ran on development itself — there is no branch to land")
    }

    /// Empty `commits` is how "nothing to land" is expressed. There is no ahead/behind on
    /// this route at all, which is why the gate counts commits instead.
    func testNothingToLandIsAnEmptyCommitsArray() throws {
        let report = try decode(LandReport.self, landJSON)
        XCTAssertTrue(report.commits.isEmpty)
    }

    /// `collides` is the engine's own conflict preview — this branch against its base.
    /// Distinct from helm's cross-kild derivation, and not to be labelled derived.
    func testCollidesIsOnTheWireAndIsNotADerivation() throws {
        let report = try decode(LandReport.self, landJSON)
        XCTAssertEqual(report.collides, [])
        XCTAssertNotNil(report.collides, "present and empty, not absent")
    }

    func testDecodesACommitCarriedByALand() throws {
        let json = """
            {
              "base": "development", "branch": "kild/x",
              "commits": [{
                "sha": "abc123", "subject": "fix the thing", "author": "rasmus",
                "ts": 1785180000000, "filesChanged": 2, "additions": 40, "deletions": 8
              }],
              "files": ["A.swift"], "collides": [],
              "wouldMerge": true, "merged": false, "dryRun": true
            }
            """
        let report = try decode(LandReport.self, json)
        XCTAssertEqual(report.commits.first?.sha, "abc123")
        XCTAssertEqual(report.commits.first?.additions, 40)
        XCTAssertTrue(report.wouldMerge)
    }
}

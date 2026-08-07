import XCTest

@testable import Helm

/// **"Enter submits, Shift+Enter starts a line" is written twice, and this is what notices when
/// only one copy gets fixed.**
///
/// #278 made the rule a modifier — `submitOnReturnInsertNewlineOnShift`, in
/// `Sources/Helm/Shared/SubmitOnReturn.swift` — and routed the Archon rail and the canvas comment
/// field through it. `ChatComposer`, the caller it was first written for, still spells the same
/// five lines out inline, because `Sources/Helm/Chat/` was another slice's file and in flight.
///
/// **This duplicate is not honest and does not pretend to be.** `AGENTS.md` allows one only where
/// a runtime boundary makes sharing impossible — `hooks/` against `pi/`, `HelmWire` against
/// `tools/*.swift` — and `Chat/` and `Shared/` are the same target, compiled by the same
/// `swift build`. So the obligation is the one `SpoolWireConformanceTests` and
/// `SurfaceFailureRecipeTests` already carry for their own twice-written rules: while it exists,
/// it must be **detectable**. #292 is the conversion that removes it.
///
/// **What the behavioural suites cannot see, which is why this reads source text.**
/// `ChatComposerReturnTests`, `ArchonRailReturnTests` and `CanvasCommentFieldReturnTests` each
/// hold their own caller to today's rule, and each has a held-Shift+Return case — measured red
/// against a `phases: [.down]` build. What none of them can notice is the *modifier* gaining
/// something the inline copy never hears about: a fourth phase, a different modifier test, a
/// second key. Nothing would fail, and the chat composer would quietly keep the old behaviour.
/// The two copies share no symbol to compare instead, which is the whole defect.
///
/// **It bows out when the duplicate is gone.** Its subject is the second copy; once `ChatComposer`
/// calls the modifier there is nothing left to compare, and the skip says so and asks to be
/// deleted — `AGENTS.md` forbids deleting a test to go green but asks for exactly this when the
/// subject genuinely no longer exists. The *modifier* losing its `.onKeyPress` is a different
/// event and fails rather than skips: that one is a change to the live rule.
final class SubmitOnReturnParityTests: XCTestCase {
    private static let modifierPath = "Sources/Helm/Shared/SubmitOnReturn.swift"
    private static let composerPath = "Sources/Helm/Chat/ChatComposer.swift"

    /// **The phase set is the half that was got wrong once already.** `.down` alone does not skip
    /// an auto-repeat tick — it lets it fall through to AppKit, reach `insertNewline:` and submit
    /// — so a reviewer caught it on #275 and it was reproduced before it was believed. It is one
    /// token, invisible at a glance, and duplicated: exactly the thing to compare.
    func testBothCopiesClaimTheSameReturnPhases() throws {
        let composer = try phasesInTheInlineCopy()
        let modifier = try XCTUnwrap(
            phases(in: try source(of: Self.modifierPath)),
            "\(Self.modifierPath) no longer spells out `.onKeyPress(.return, phases: …)`, so "
                + "this test cannot compare the two copies of the rule. Rewrite it against "
                + "whatever replaced it.")

        XCTAssertEqual(
            composer, modifier,
            "ChatComposer's hand-written copy of the Return rule claims \(composer) where "
                + "submitOnReturnInsertNewlineOnShift claims \(modifier). One was changed and "
                + "the other was not — #292 removes the copy.")
    }

    /// The other half: *which* Return is claimed. A copy that stopped checking `.shift` would
    /// swallow plain Enter and the composer would never send anything; one that checked something
    /// else would leave Shift+Enter submitting, which is #119 all over again.
    func testBothCopiesClaimOnlyTheShiftedReturn() throws {
        _ = try phasesInTheInlineCopy()
        let claim = "guard press.modifiers.contains(.shift) else { return .ignored }"
        for path in [Self.modifierPath, Self.composerPath] {
            XCTAssertTrue(
                try source(of: path).contains(claim),
                "\(path) no longer claims only the shifted Return with "
                    + "\(claim.debugDescription) — the two copies have diverged, see #292")
        }
    }

    // MARK: - Reading the two copies

    /// `ChatComposer`'s phase set, or the end of this file's reason to exist.
    private func phasesInTheInlineCopy() throws -> String {
        guard let phases = phases(in: try source(of: Self.composerPath)) else {
            throw XCTSkip(
                """
                \(Self.composerPath) no longer spells out `.onKeyPress(.return, phases: …)`.

                If that is because it now calls submitOnReturnInsertNewlineOnShift, then #292 has \
                landed, the second copy of the rule is gone, and THIS FILE'S SUBJECT NO LONGER \
                EXISTS — delete it and say so in the commit, per AGENTS.md.
                """)
        }
        return phases
    }

    /// The `phases:` argument of a file's `.onKeyPress(.return, …)`, as written.
    private func phases(in text: String) -> String? {
        let marker = ".onKeyPress(.return, phases: "
        guard let start = text.range(of: marker),
            let end = text[start.upperBound...].firstIndex(of: "]")
        else { return nil }
        return String(text[start.upperBound...end])
    }

    private func source(of path: String) throws -> String {
        // The repo root from this file's own location, so the read does not depend on where the
        // tests were invoked from — `SurfaceFailureRecipeTests` reaches for `AGENTS.md` the same
        // way, and for the same reason: the rule is stated in a file no compiler reads.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Shared/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
        return try XCTUnwrap(
            try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8),
            "could not read \(path)")
    }
}

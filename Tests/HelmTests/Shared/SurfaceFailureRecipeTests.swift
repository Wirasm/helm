import XCTest

@testable import Helm

/// The surface-failure evidence recipe is written twice, and this is what notices when only one
/// copy gets fixed.
///
/// **The duplicate is honest and the drift already happened.** `AGENTS.md` tells an agent what to
/// run before blaming a red keyboard suite on the environment; `MissingTerminalSurface.description`
/// tells them the same thing at the moment the suite goes red, which is where they actually read
/// it. A Markdown paragraph and a Swift string literal have no shared mechanism between them — the
/// same carve-out `hooks/`/`pi/` and the spool scripts get, for the same reason — so the obligation
/// is not that it be shared but that it be **detectable**, exactly as `SpoolWireConformanceTests`
/// is for the spool's twice-written wire format.
///
/// Nothing checked it until now, and the cost is measured: **both copies carried the identical
/// broken command** — bare `log show`, which is a zsh *builtin* and so never reached `/usr/bin/log`
/// at all, and a predicate naming ghostty alone, which could not have shown the CoreVideo line that
/// identifies the cause. Three agents read the resulting empty pipeline as "the log is empty" while
/// 3562 lines sat in it (#249, #253). Neither copy knew the other existed, so being wrong in both
/// places at once looked exactly like being right.
///
/// **What this holds and what it does not.** It compares the two literals; it does not run the
/// command. Whether `/usr/bin/log` answers is a fact about the machine rather than about helm, and
/// a `log show` inside `swift test` would make the Swift gate depend on the unified log — the gate
/// deliberately needs only the toolchain and xcodegen. The command was executed under zsh, fish and
/// bash when it was written, by extracting it from each file rather than retyping it, which is the
/// verification a *test* cannot repeat and the one #249 says was missing the first time.
final class SurfaceFailureRecipeTests: XCTestCase {
    /// The repo root, from this file's own location, so the read does not depend on where the
    /// tests were invoked from — `PaletteRuleTests` and `DefaultsDomainTests` reach for `AGENTS.md`
    /// the same way, and for the same reason: the rule is stated in a file no compiler reads.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Shared/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }

    /// The recipe as the failing test prints it, with Swift's line continuations already applied.
    private var messageRecipe: String {
        logCommand(in: MissingTerminalSurface(pane: UUID(), waited: 0).description)
    }

    /// The recipe as `AGENTS.md` prints it, with the fenced block's `\`-continuations joined.
    private var documentedRecipe: String {
        let agents =
            (try? String(
                contentsOf: repositoryRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8))
            ?? ""
        return logCommand(in: agents.replacingOccurrences(of: "\\\n", with: " "))
    }

    /// The one line starting `/usr/bin/log`, whitespace-collapsed so indentation and wrapping — the
    /// two things that legitimately differ between a Markdown fence and a Swift literal — are not
    /// what this test is comparing.
    private func logCommand(in text: String) -> String {
        let line =
            text
            .split(separator: "\n")
            .first { $0.contains("/usr/bin/log") }
            .map(String.init) ?? ""
        return line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    func testTheDocumentedRecipeAndTheOneTheSuitePrintsAreTheSameCommand() {
        XCTAssertFalse(
            documentedRecipe.isEmpty,
            "AGENTS.md must carry the recipe — an agent who has not yet seen a red suite reads it "
                + "there first")
        XCTAssertFalse(
            messageRecipe.isEmpty,
            "MissingTerminalSurface must carry it too — that is where an agent meets it at the "
                + "moment it matters")
        XCTAssertEqual(
            documentedRecipe, messageRecipe,
            "AGENTS.md and MissingTerminalSurface state the same recipe and nothing else compares "
                + "them. Fix both, or neither is worth reading (#249)")
    }

    /// The three substrings the recipe is *for*, asserted on both copies by name.
    ///
    /// Equality alone would be satisfied by two identical copies of the broken command — which is
    /// precisely the state #249 found. These are the parts that were wrong: the absolute path,
    /// because `log` is a zsh builtin and zsh is what Claude Code's Bash tool runs; and both
    /// subsystems, because ghostty's line ties the failure to a surface while CoreVideo's is the
    /// one that names the cause.
    func testBothCopiesUseTheAbsolutePathAndAskBothSubsystems() {
        for (name, recipe) in [("AGENTS.md", documentedRecipe), ("the suite", messageRecipe)] {
            XCTAssertTrue(
                recipe.contains("/usr/bin/log"),
                "\(name): a bare `log` is zsh's builtin, which answers `too many arguments` and — "
                    + "through a pipe — exits 0 with no output (#249)")
            XCTAssertTrue(
                recipe.contains("com.mitchellh.ghostty"),
                "\(name): ghostty's line is what ties the failure to a surface")
            XCTAssertTrue(
                recipe.contains("com.apple.corevideo"),
                "\(name): CoreVideo's line is the one that names the cause — `error.OutOfMemory` "
                    + "is ghostty's misleading name for a failed display link (#253)")
        }
    }
}

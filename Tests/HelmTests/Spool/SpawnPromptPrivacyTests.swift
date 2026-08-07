import XCTest

@testable import HelmWire

/// The GUI spawn path's half of #93, checked where it actually lives.
///
/// **Why this reads a file instead of running one.** `SpoolLaunchLine` is a type both `Helm` and
/// this test compile against, so the spool half of #93 is measured by *executing* it
/// (`SpoolPolicyTests.testAShellRunningTheLaunchLineNeverPutsThePromptInTheAgentsArgv` runs a real
/// `/bin/sh` and reads the argv that comes out). `tools/helm-spawn.swift` cannot join that: it is a
/// single-file script with top-level code, deliberately so — `AGENTS.md`'s *"Why the spool is a
/// script, and must stay one"* has the measurements — and it composes its launch line inline,
/// after a preflight that needs a running helm, an unlocked screen and an Accessibility grant.
/// There is no way to reach that expression from `swift test` at all.
///
/// So the guard is on the **property**, read out of the real file: no command substitution, and
/// the same sentence `SpoolLaunchLine.promptPointer` composes. That is the same trade the mail
/// skills' gate makes — it extracts snippets from `SKILL.md` and runs them rather than restating
/// them, because *"a test that retypes a documented snippet is a second copy that drifts"*. Here
/// the second copy is unavoidable (a script cannot import `HelmWire`); what is not optional is
/// that a drift in either direction fails a test.
final class SpawnPromptPrivacyTests: XCTestCase {
    private var helmSpawnSource: String {
        get throws {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent("tools/helm-spawn.swift"),
                encoding: .utf8)
        }
    }

    func testHelmSpawnNeverAsksTheShellToExpandThePromptOntoTheCommandLine() throws {
        // `cls "$(cat …)"` reads as private and is not: the shell expands the substitution before
        // exec, so the whole prompt becomes an argv element of `claude` and any `ps` reader has
        // it. Measured live 2026-08-07 against a running spool-spawned agent (#93).
        //
        // Read off the composing expression rather than the whole file, deliberately: the header
        // and two refusal comments still *quote* the old form to explain what was measured and
        // why, and a test that forbade the characters anywhere would be a test against recording
        // the finding.
        let composition = try XCTUnwrap(
            try helmSpawnSource.split(separator: "\n").first(where: {
                $0.hasPrefix("let line = ")
            }),
            "tools/helm-spawn.swift no longer composes its launch line as a top-level `let line`")
        XCTAssertFalse(
            composition.contains("$("),
            "the launch line still asks the shell to substitute: \(composition)")
        XCTAssertFalse(
            composition.contains("`"),
            "backticks are a command substitution too: \(composition)")
        XCTAssertTrue(
            composition.contains("promptPointer("),
            "the launch line must hand over a pointer, not the prompt: \(composition)")
    }

    func testHelmSpawnSaysTheSameSentenceTheSpoolSays() throws {
        // Adjacent Swift literals joined with `+` are one string once compiled, so undo that
        // before looking: the script wraps the sentence across lines exactly as `HelmWire` does.
        let source = try helmSpawnSource.replacingOccurrences(
            of: "\"\\s*\\+\\s*\"", with: "", options: .regularExpression)
        // Split the composed pointer around the path so the two literal halves can be looked for
        // in a file that builds them by interpolation. Either side changing the wording without
        // the other fails here, which is the whole reason this test exists.
        let marker = "<<<PATH>>>"
        let halves = SpoolLaunchLine.promptPointer(to: marker).components(separatedBy: marker)
        XCTAssertEqual(halves.count, 2, "promptPointer must mention the path exactly once")
        for half in halves {
            // The literal is written with `\"` where the composed sentence has a bare quote.
            let asWritten = half.replacingOccurrences(of: "\"", with: "\\\"")
            XCTAssertTrue(
                source.contains(asWritten),
                "tools/helm-spawn.swift no longer says what SpoolLaunchLine.promptPointer says. "
                    + "Missing: \(asWritten)")
        }
    }

    func testHelmSpawnKeepsThePromptFileUntilTheAgentCanHaveReadIt() throws {
        let source = try helmSpawnSource
        // With `$(cat …)` the prompt was consumed at exec, so deleting the scratch directory the
        // moment the session registered was safe. It is not any more: registration happens when
        // the agent's row appears, which is *before* its first turn reads the file. A delete on
        // the success path would race the agent to its own instructions.
        let lastRefusal = try XCTUnwrap(source.range(of: ".agentNeverRegistered)"))
        let afterTheLastRefusal = String(source[lastRefusal.upperBound...])
        XCTAssertFalse(
            afterTheLastRefusal.contains("removeItem(at: scratch)"),
            "helm-spawn deletes the prompt file on the success path, where the agent has not "
                + "read it yet")
    }

    /// Four levels up from `Tests/HelmTests/Spool/`, the same walk `SpoolWireConformanceTests`
    /// does — a test that reads a file no compiler touches has to find it itself.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Spool/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}

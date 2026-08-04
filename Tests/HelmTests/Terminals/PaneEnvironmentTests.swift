import XCTest

@testable import Helm

/// **Which session am I?** asked from inside a pane, and the two ways helm used to answer it
/// wrong: with nothing of its own (#94), and with the launching session's `CLAUDE_*` (#139).
@MainActor
final class PaneEnvironmentTests: XCTestCase {
    private let workspace = "/tmp/helm-pane-environment"

    // MARK: - The pane's own identity (#94)

    func testAPaneCarriesItsOwnIDIntoTheChildEnvironment() {
        let manager = TerminalManager()
        let session = manager.newTerminal(in: workspace)

        XCTAssertEqual(
            session.hostView.configuration.envVars[PaneEnvironment.paneVariable],
            session.id.uuidString,
            "the uuid the child is spawned with must be the session's own id, not any other")
    }

    /// Two panes are two identities. A shared constant would pass the test above and fail
    /// the only question worth asking.
    func testEveryPaneGetsADistinctIdentity() {
        let manager = TerminalManager()
        let first = manager.newTerminal(in: workspace)
        let second = manager.newTerminal(in: workspace)

        let firstPane = first.hostView.configuration.envVars[PaneEnvironment.paneVariable]
        let secondPane = second.hostView.configuration.envVars[PaneEnvironment.paneVariable]

        XCTAssertNotNil(firstPane)
        XCTAssertNotEqual(firstPane, secondPane, "two panes must not share one identity")
    }

    /// #94's second acceptance line. Restore rebuilds the row under the ids it persisted, so
    /// a relaunched pane keeps the identity anything written on disk already names.
    func testARestoredPaneKeepsThePersistedIdentity() {
        let manager = TerminalManager()
        let persisted = UUID()

        manager.activate(workspacePath: workspace, restoring: [persisted])

        XCTAssertEqual(
            manager.sessions(for: workspace).first?.hostView.configuration
                .envVars[PaneEnvironment.paneVariable],
            persisted.uuidString,
            "a pane restored after relaunch must publish the id it was persisted under")
    }

    /// The declaration the grid needs is still there — the identity is added to it, not
    /// substituted for it.
    func testThePaneEnvironmentStillDeclaresTheTerminal() {
        let environment = PaneEnvironment.forPane(UUID())

        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(environment["TERM_PROGRAM"], "ghostty")
    }

    // MARK: - The identity helm refuses to pass on (#139)

    /// The six names measured on the running instance in #139, plus pi's own three.
    func testEveryLeakedAgentIdentityVariableIsDropped() {
        let leaked = [
            "CLAUDE_CODE_SESSION_ID": "b39e7b14-6233-4894-98d7-f31e75da2dd3",
            "CLAUDE_PID": "56062",
            "CLAUDE_CODE_BRIDGE_SESSION_ID": "session_01Lrd2qwd49yRYQLQNkRGmXR",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_EFFORT": "xhigh",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "PI_SESSION_ID": "01J0",
            "PI_SESSION_FILE": "/tmp/pi.json",
            "PI_CODING_AGENT": "true",
        ]

        XCTAssertEqual(
            Set(PaneEnvironment.staleIdentityKeys(in: leaked)), Set(leaked.keys),
            "a variable naming somebody else's session must not survive into a pane")
    }

    /// The other half, and the one a prefix rule can get wrong. Credentials and the ordinary
    /// shell environment are not identity claims and must go through untouched.
    func testTheOrdinaryEnvironmentSurvivesUntouched() {
        let inherited = [
            "PATH": "/usr/bin",
            "HOME": "/Users/someone",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "SHELL": "/bin/zsh",
            // Credentials a hosted agent needs. Stripping these would break the agent
            // outright, which is why the rule is about identity and not about vendors.
            "ANTHROPIC_API_KEY": "sk-ant-not-a-real-key",
            "ANTHROPIC_MODEL": "claude-opus-4",
            // Near-misses for the prefixes: `PI_` has the underscore precisely so these do
            // not match.
            "PIP_REQUIRE_VIRTUALENV": "true",
            "PIPENV_VENV_IN_PROJECT": "1",
            // helm's own, and ghostty's — both are helm telling the child the truth.
            "HELM_DEFAULTS_SUITE": "helm-bench",
            "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources/ghostty",
        ]

        XCTAssertEqual(
            PaneEnvironment.staleIdentityKeys(in: inherited), [],
            "the rule must take out session identity and nothing else")
    }

    /// `unsetenv` and not an empty value: libghostty's per-surface `env_vars` hook is a `put`
    /// into ghostty's config map and cannot unset, so `CLAUDE_CODE_SESSION_ID=` would still
    /// be a second answer sitting next to `HELM_PANE`. Removal has to happen in helm's own
    /// process, which is what this proves.
    func testRemovingStaleIdentityTakesItOutOfTheProcessEnvironment() throws {
        setenv("CLAUDE_CODE_SESSION_ID", "not-this-pane", 1)
        setenv("PI_SESSION_ID", "not-this-pane-either", 1)
        defer {
            unsetenv("CLAUDE_CODE_SESSION_ID")
            unsetenv("PI_SESSION_ID")
        }

        // Handed the dictionary rather than left to read `ProcessInfo`, whose `environment`
        // is a snapshot and need not show a `setenv` made after it was first taken. What is
        // under test is that a listed key is actually removed from `environ`, not how the
        // list is obtained.
        PaneEnvironment.removeStaleIdentity(from: [
            "CLAUDE_CODE_SESSION_ID": "not-this-pane",
            "PI_SESSION_ID": "not-this-pane-either",
            "PATH": "/usr/bin",
        ])

        XCTAssertNil(getenv("CLAUDE_CODE_SESSION_ID"))
        XCTAssertNil(getenv("PI_SESSION_ID"))
        XCTAssertNotNil(getenv("PATH"), "the scrub must not empty the environment wholesale")
    }
}

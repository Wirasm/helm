import HelmWire
import XCTest

@testable import Helm

/// **Which session am I?** asked from inside a pane, and the two ways helm used to answer it
/// wrong: with nothing of its own (#94), and with the launching session's `CLAUDE_*` (#139).
@MainActor
final class PaneEnvironmentTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-pane-environment")

    // MARK: - The pane's own identity (#94)

    func testAPaneCarriesItsOwnIDIntoTheChildEnvironment() {
        let manager = TerminalManager()
        let session = manager.adoptShell(in: workspace)

        XCTAssertEqual(
            session.hostView.configuration.envVars[PaneEnvironment.paneVariable],
            session.id.uuidString,
            "the uuid the child is spawned with must be the session's own id, not any other")
    }

    /// Two panes are two identities. A shared constant would pass the test above and fail
    /// the only question worth asking.
    func testEveryPaneGetsADistinctIdentity() {
        let manager = TerminalManager()
        let first = manager.adoptShell(in: workspace)
        let second = manager.adoptShell(in: workspace)

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

        manager.adopt(terminals: [persisted], in: workspace)

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

    // MARK: - Which instance the child belongs to (#285)

    /// **The half of #285 that is helm's.** The spool scripts an agent runs, and `bench` through
    /// `BENCH_SUITE`, are processes helm does not run and that cannot ask it anything — so the
    /// only way an isolated instance's agents reach its state rather than the operator's is for
    /// helm to say which instance they are in. Declared rather than inherited, for the
    /// reason `terminalDeclaration` gives about `COLORTERM`.
    func testAnIsolatedInstanceTellsItsChildrenWhichInstanceTheyAreIn() {
        let environment = PaneEnvironment.forPane(
            UUID(), environment: ["HELM_DEFAULTS_SUITE": "drivetest"])

        XCTAssertEqual(environment["HELM_DEFAULTS_SUITE"], "drivetest")
    }

    /// The other half, and the one that keeps the ordinary case ordinary: with no suite there is
    /// nothing to say, and a variable saying "no suite" would be a second way to spell the
    /// default for the two writers to disagree about.
    func testTheOperatorsOwnHelmDeclaresNoSuiteAtAll() {
        XCTAssertNil(PaneEnvironment.forPane(UUID(), environment: [:])["HELM_DEFAULTS_SUITE"])
        XCTAssertNil(
            PaneEnvironment.forPane(UUID(), environment: ["HELM_DEFAULTS_SUITE": ""])[
                "HELM_DEFAULTS_SUITE"])
    }

    // MARK: - Which bench the child belongs to (#393)

    /// What `bench` in a pane resolves: it reads `BENCH_*` and nothing of helm's, so this is
    /// the child's environment with every other variable taken out.
    private func benchRootInPane(of helm: [String: String]) -> Result<URL, BenchRootError> {
        let child = helm.merging(PaneEnvironment.forPane(UUID(), environment: helm)) { $1 }
        return BenchRoot.resolve(
            environment: child.filter { $0.key.hasPrefix("BENCH_") },
            home: URL(fileURLWithPath: "/Users/op"))
    }

    /// **The pane and the agent in it look at one bench.** helm's browser pane resolves its root
    /// with `BenchRoot` from helm's environment (#378). An agent in a pane runs `bench`, which
    /// resolves from the child's `BENCH_*` alone. Before #393 an isolated helm declared only
    /// `HELM_DEFAULTS_SUITE`, so the pane showed `~/.bench-<suite>` while the agent drove the
    /// operator's `~/.bench`.
    func testAnAgentInAPaneResolvesTheBenchThePaneShows() throws {
        let home = URL(fileURLWithPath: "/Users/op")
        let fixtures: [[String: String]] = [
            [:],
            ["HELM_DEFAULTS_SUITE": "drivetest"],
            ["HELM_DEFAULTS_SUITE": "com.wirasm.helm"],
            ["HELM_DEFAULTS_SUITE": "drivetest", "BENCH_SUITE": "other"],
            ["HELM_DEFAULTS_SUITE": "drivetest", "BENCH_DIR": "/tmp/bench"],
        ]
        for helm in fixtures {
            let pane = try BenchRoot.resolve(environment: helm, home: home).get()
            XCTAssertEqual(try benchRootInPane(of: helm).get(), pane, "helm environment \(helm)")
        }
    }

    /// A suite helm runs under but benchd cannot name: the pane refuses it, and so must `bench`
    /// in the pane. Falling back to `~/.bench` is the leak.
    func testASuiteBenchdCannotNameIsRefusedInThePaneToo() {
        let helm = ["HELM_DEFAULTS_SUITE": "Helm-Bench"]
        XCTAssertThrowsError(
            try BenchRoot.resolve(environment: helm, home: URL(fileURLWithPath: "/Users/op")).get())
        XCTAssertThrowsError(
            try benchRootInPane(of: helm).get(), "an agent must not reach the shared ~/.bench")
    }

    /// The operator's own helm declares no bench suite: his agents reach his own bench.
    func testTheOperatorsOwnHelmDeclaresNoBenchSuite() {
        XCTAssertNil(PaneEnvironment.forPane(UUID(), environment: [:])["BENCH_SUITE"])
        XCTAssertNil(
            PaneEnvironment.forPane(
                UUID(), environment: ["HELM_DEFAULTS_SUITE": "com.wirasm.helm"])[
                    "BENCH_SUITE"])
    }

    /// **The wiring, which no fixture can prove.** `TerminalSession` calls `forPane(id)` with no
    /// environment argument, so the default parameter *is* the mechanism — and every test above
    /// hands in a dictionary and would go on passing if that default were `[:]`. This one asks
    /// the process the app asks.
    func testAPaneReadsTheSuiteFromTheProcessTheAppActuallyRunsIn() {
        setenv(DefaultsSuite.suiteVariable, "helm-tests-pane-suite", 1)
        defer { unsetenv(DefaultsSuite.suiteVariable) }

        XCTAssertEqual(
            PaneEnvironment.forPane(UUID())[DefaultsSuite.suiteVariable], "helm-tests-pane-suite",
            "the default argument must read this process's environment, not an empty one")
    }

    /// **A child is never told a suite helm itself refused.** `DefaultsDomain.resolve` stops the
    /// launch on one, so publishing the raw value would be helm handing an agent a name it would
    /// not run under — and the agent's scripts would then write where no helm reads.
    func testASuiteHelmWouldRefuseIsNeverDeclaredToAChild() {
        for refused in ["   ", "com.wirasm.helm", "helm", "/Users/nobody/somewhere"] {
            XCTAssertNil(
                PaneEnvironment.forPane(UUID(), environment: ["HELM_DEFAULTS_SUITE": refused])[
                    "HELM_DEFAULTS_SUITE"],
                "\(refused.debugDescription) is not a suite helm runs under; a pane must not be told it is"
            )
        }
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

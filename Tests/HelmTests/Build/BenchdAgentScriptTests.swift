import XCTest

/// `scripts/benchd-agent.sh` and the launchd half of `release-resume.sh` (#407), sourced and run
/// against fakes.
///
/// Fakes and helpers: `BenchdAgentHarness`. `--listen` and what an install does around benchd's
/// restart: `BenchdAgentListenTests`.
final class BenchdAgentScriptTests: BenchdAgentHarness {
    /// `release-resume.sh`'s restart, sourced and run for one bench suite.
    private func restartBenchd(
        suite: String
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        try bash([
            "-c", "source \"$1\"; bench_suite=\"$2\"; restart_benchd \"$3\"", "test",
            scripts.appendingPathComponent("release-resume.sh").path, suite, bin.path,
        ])
    }

    func testReleaseResumeRestartsALoadedAgentThroughLaunchdAndStartsNoBenchdOfItsOwn() throws {
        try writeFakes()
        FileManager.default.createFile(
            atPath: scratch.appendingPathComponent("loaded").path, contents: nil)

        let run = try restartBenchd(suite: "probe")
        XCTAssertEqual(run.status, 0, run.stderr)

        let uid = getuid()
        let log = recorded()
        XCTAssertTrue(
            log.contains("launchctl kickstart -k gui/\(uid)/com.wirasm.benchd.probe"), log)
        XCTAssertFalse(
            lines(log).contains("benchd"), "a second benchd was started by hand:\n\(log)")
        XCTAssertFalse(log.contains("bench stop"), log)
        XCTAssertFalse(
            log.contains("bench browser start"), "the browser is benchd's to bring back:\n\(log)")
        XCTAssertTrue(run.stdout.contains("benchd pid 101 under launchd"), run.stdout)
    }

    /// The control: without an agent, the restart is the one #406 shipped, and launchd is not
    /// asked to do anything. This must pass on the base tree too.
    func testReleaseResumeWithoutAnAgentStopsAndStartsBenchdItself() throws {
        try writeFakes()

        let run = try restartBenchd(suite: "probe")
        XCTAssertEqual(run.status, 0, run.stderr)

        let log = recorded()
        XCTAssertTrue(log.contains("bench stop"), log)
        XCTAssertTrue(lines(log).contains("benchd"), log)
        XCTAssertTrue(log.contains("bench browser start"), log)
        XCTAssertFalse(log.contains("kickstart"), log)
    }

    /// `launchctl print` exiting 124 is what `timeout` reports when it hangs: nobody knows whether
    /// launchd runs benchd, so starting one by hand could put a second benchd beside launchd's.
    func testReleaseResumeLeavesBenchdAloneWhenLaunchdCannotBeAsked() throws {
        try writeFakes()
        FileManager.default.createFile(
            atPath: scratch.appendingPathComponent("hung").path, contents: nil)

        let run = try restartBenchd(suite: "probe")
        XCTAssertEqual(run.status, 0, run.stderr)

        let log = recorded()
        XCTAssertFalse(lines(log).contains("benchd"), "a benchd was started by hand:\n\(log)")
        XCTAssertFalse(log.contains("bench stop"), log)
        XCTAssertFalse(log.contains("kickstart"), log)
        XCTAssertTrue(run.stdout.contains("launchctl did not answer"), run.stdout)
    }

    func testInstallRefusesASuiteAndTouchesNothing() throws {
        try writeFakes()
        for variable in ["BENCH_SUITE", "BENCH_DIR"] {
            let run = try bash(
                [scripts.appendingPathComponent("benchd-agent.sh").path, "install"],
                environment: [variable: "probe"])
            XCTAssertEqual(run.status, 3, "\(variable): \(run.stderr)")
            XCTAssertTrue(run.stderr.contains("only the live benchd"), run.stderr)
        }
        XCTAssertEqual(recorded(), "", "a refused install called launchctl, cargo or bench")

        // An empty BENCH_DIR is unset, as bench and helm read it (#412): not a refusal.
        let empty = try bash(
            [scripts.appendingPathComponent("benchd-agent.sh").path, "install", "--no-build"],
            environment: ["BENCH_DIR": ""])
        XCTAssertEqual(empty.status, 4, empty.stderr)
        XCTAssertTrue(empty.stderr.contains("no bench/benchd"), empty.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent("Library/LaunchAgents").path))
    }

    func testThePlistRestartsACrashNotACleanStopAndCarriesTheSuiteOnlyWhenGiven() throws {
        let agent = try plist(suite: "probe")
        XCTAssertEqual(agent["Label"] as? String, "com.wirasm.benchd.probe")
        XCTAssertEqual(agent["ProgramArguments"] as? [String], ["/opt/bench/benchd"])
        XCTAssertEqual(agent["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((agent["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
        XCTAssertEqual(agent["StandardErrorPath"] as? String, "/tmp/benchd-probe.log")
        let env = try XCTUnwrap(agent["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["BENCH_SUITE"], "probe")
        XCTAssertTrue(
            env["PATH"]?.contains(bin.path) == true, "the installer's PATH, so agents resolve")

        let live = try plist(suite: nil)
        let liveEnv = try XCTUnwrap(live["EnvironmentVariables"] as? [String: String])
        XCTAssertNil(liveEnv["BENCH_SUITE"])
    }

    /// The self-updating installs in ~/.local/bin beat a stale Homebrew codex (G4): a cask in
    /// /opt/homebrew/bin ahead of it in the installer's PATH made every spawned codex 0.157.0.
    func testThePlistPutsLocalBinFirstSoAgentsRunTheSelfUpdatingInstall() throws {
        let local = scratch.appendingPathComponent(".local/bin").path
        let path = scratch.appendingPathComponent("agent.plist")
        let run = try bash(
            [
                "-c", "source \"$1\"; shift; write_plist \"$@\"", "test",
                scripts.appendingPathComponent("benchd-agent.sh").path,
                path.path, "com.wirasm.benchd.probe", "/opt/bench/benchd", "/tmp/benchd-probe.log",
            ],
            environment: ["PATH": "\(bin.path):/opt/homebrew/bin:\(local):/usr/bin:/bin"])
        XCTAssertEqual(run.status, 0, run.stderr)
        let agent = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil)
                as? [String: Any])
        let env = try XCTUnwrap(agent["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(
            env["PATH"], "\(local):\(bin.path):/opt/homebrew/bin:/usr/bin:/bin",
            "~/.local/bin first, once, and the rest in the installer's order")
    }
}

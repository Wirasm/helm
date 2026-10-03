import XCTest

/// `scripts/benchd-agent.sh` and the launchd half of `release-resume.sh` (#407), sourced and run
/// against fakes.
///
/// `launchctl`, `cargo`, `bench` and `benchd` are shell scripts in a scratch directory that write
/// what they were asked into `calls`, so nothing here loads a launch agent or touches a benchd.
/// The real launchd path is proved by `just launchd-proof` in `daemon/`, recorded on the PR.
final class BenchdAgentScriptTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchd-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        scratch = scratch.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
    }

    private var scripts: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Build
            .deletingLastPathComponent()  // HelmTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("scripts")
    }

    private var bin: URL { scratch.appendingPathComponent("bin") }
    private var calls: URL { scratch.appendingPathComponent("calls") }

    private func recorded() -> String {
        (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
    }

    private func lines(_ log: String) -> [Substring] { log.split(separator: "\n") }

    /// Fakes that record every call. `launchctl print` answers "loaded" when `loaded` exists;
    /// `kickstart` and `benchd` bump the pid `bench status` reports; `bench status` answers only
    /// while `up` exists, and `bench stop` removes it.
    private func writeFakes() throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Where release-resume writes benchd's log; a real HOME always has it.
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
        let state = scratch.path
        let fakes = [
            "launchctl": """
            echo "launchctl $*" >> \(state)/calls
            case "$1" in
            print) [ -e \(state)/hung ] && exit 124; [ -e \(state)/loaded ] || exit 113 ;;
            kickstart) echo $(( $(cat \(state)/pid) + 1 )) > \(state)/pid ;;
            esac
            """,
            // The scripts bound every step with `timeout`, which macOS does not ship (CI has none;
            // a workstation usually has coreutils'). Nothing here depends on a real deadline, and
            // a hang is the fake launchctl exiting 124 itself, so this one drops the duration.
            "timeout": #"shift; exec "$@""#,
            "cargo": #"echo "cargo $*" >> \#(state)/calls"#,
            "bench": """
            echo "bench $*" >> \(state)/calls
            case "$1" in
            status) [ -e \(state)/up ] || exit 2; printf '{"pid": %s}\\n' "$(cat \(state)/pid)" ;;
            stop) rm -f \(state)/up ;;
            esac
            """,
            "benchd": """
            echo "benchd" >> \(state)/calls
            echo $(( $(cat \(state)/pid) + 1 )) > \(state)/pid
            touch \(state)/up
            """,
        ]
        for (name, body) in fakes {
            let path = bin.appendingPathComponent(name)
            try "#!/bin/bash\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try "100\n".write(
            to: scratch.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(
            atPath: scratch.appendingPathComponent("up").path, contents: nil)
    }

    private func bash(
        _ arguments: [String], environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // The fakes first, then the caller's PATH for everything else the scripts run.
        env["PATH"] = "\(bin.path):\(env["PATH"] ?? "/usr/bin:/bin")"
        env["HOME"] = scratch.path
        env.removeValue(forKey: "BENCH_SUITE")
        env.removeValue(forKey: "BENCH_DIR")
        // Cargo's bin must be the scratch HOME's, which holds no bench or benchd.
        env.removeValue(forKey: "CARGO_HOME")
        env.removeValue(forKey: "CARGO_INSTALL_ROOT")
        process.environment = env.merging(environment) { $1 }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self)
        )
    }

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

    private func plist(suite: String?, listen: String? = nil) throws -> [String: Any] {
        let path = scratch.appendingPathComponent("agent.plist")
        var args = [
            "-c", "source \"$1\"; shift; write_plist \"$@\"", "test",
            scripts.appendingPathComponent("benchd-agent.sh").path,
            path.path, "com.wirasm.benchd.probe", "/opt/bench/benchd", "/tmp/benchd-probe.log",
        ]
        if suite != nil || listen != nil { args.append(suite ?? "") }
        if let listen { args.append(listen) }
        let run = try bash(args)
        XCTAssertEqual(run.status, 0, run.stderr)
        let data = try Data(contentsOf: path)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
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

    /// Pocket reaches benchd over TCP (#625): the agent's benchd listens where `--listen` said,
    /// and only then.
    func testThePlistCarriesTheListenAddressOnlyWhenGiven() throws {
        let listening = try plist(suite: nil, listen: "100.101.102.103:4519")
        let env = try XCTUnwrap(listening["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["BENCH_LISTEN"], "100.101.102.103:4519")
        XCTAssertNil(env["BENCH_SUITE"], "an empty suite is the live root's agent")

        let suite = try plist(suite: "probe", listen: "127.0.0.1:52230")
        let suiteEnv = try XCTUnwrap(suite["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(suiteEnv["BENCH_SUITE"], "probe")
        XCTAssertEqual(suiteEnv["BENCH_LISTEN"], "127.0.0.1:52230")

        let quiet = try plist(suite: nil)
        XCTAssertNil((quiet["EnvironmentVariables"] as? [String: String])?["BENCH_LISTEN"])
    }

    /// `resolve_listen <spec>` with `tailscale` answering `tailscale ip -4` as `answer` (nil: it
    /// fails as a stopped Tailscale does).
    private func resolve(
        _ spec: String, tailscale answer: String?
    ) throws -> (
        status: Int32, stdout: String, stderr: String
    ) {
        let body =
            answer.map { "[ \"$*\" = \"ip -4\" ] || exit 9\necho '\($0)'" }
            ?? "echo 'Tailscale is stopped.' >&2\nexit 1"
        let path = bin.appendingPathComponent("tailscale")
        try "#!/bin/bash\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return try bash([
            "-c", "source \"$1\"; resolve_listen \"$2\"", "test",
            scripts.appendingPathComponent("benchd-agent.sh").path, spec,
        ])
    }

    /// The port has no login, so the tailnet is the trust boundary: `tailscale` is the Mac's
    /// tailnet address or a refusal, never 0.0.0.0 or a LAN address in its place.
    func testListenTailscaleIsTheTailnetAddressOrARefusal() throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tailnet = try resolve("tailscale", tailscale: "100.101.102.103")
        XCTAssertEqual(tailnet.status, 0, tailnet.stderr)
        XCTAssertEqual(tailnet.stdout, "100.101.102.103:4519\n")
        let port = try resolve("tailscale:5000", tailscale: "100.101.102.103")
        XCTAssertEqual(port.stdout, "100.101.102.103:5000\n", port.stderr)

        let stopped = try resolve("tailscale", tailscale: nil)
        XCTAssertNotEqual(stopped.status, 0)
        XCTAssertEqual(stopped.stdout, "")
        XCTAssertTrue(stopped.stderr.contains("Tailscale"), stopped.stderr)
        for lan in ["192.168.1.5", "10.0.0.7", "", "100.200.1.1"] {
            let refused = try resolve("tailscale", tailscale: lan)
            XCTAssertNotEqual(refused.status, 0, "\(lan) was taken for a tailnet address")
            XCTAssertEqual(refused.stdout, "", lan)
        }
    }

    /// An address the operator names is his, except one that listens on every interface.
    func testAnExplicitListenIsTakenUnlessItIsEveryInterface() throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let loopback = try resolve("127.0.0.1:52230", tailscale: nil)
        XCTAssertEqual(loopback.stdout, "127.0.0.1:52230\n", loopback.stderr)
        for spec in ["0.0.0.0:4519", "[::]:4519", "100.101.102.103", "no-port:"] {
            let refused = try resolve(spec, tailscale: nil)
            XCTAssertNotEqual(refused.status, 0, spec)
            XCTAssertEqual(refused.stdout, "", spec)
        }
    }

    /// A `--listen` that cannot be resolved stops the install before it builds or loads anything.
    func testAnInstallWhoseListenCannotResolveTouchesNothing() throws {
        try writeFakes()
        let path = bin.appendingPathComponent("tailscale")
        try "#!/bin/bash\necho 'Tailscale is stopped.' >&2\nexit 1\n".write(
            to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        let run = try bash([
            scripts.appendingPathComponent("benchd-agent.sh").path, "install", "--listen",
            "tailscale",
        ])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.stderr.contains("Tailscale"), run.stderr)
        XCTAssertEqual(recorded(), "", "a refused install called launchctl, cargo or bench")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent("Library/LaunchAgents").path))
    }
}

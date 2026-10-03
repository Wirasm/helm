import XCTest

/// What `BenchdAgentScriptTests` and `BenchdAgentListenTests` share: a scratch HOME, the fakes
/// that record what they were asked, and the scripts run against them.
///
/// `launchctl`, `cargo`, `bench`, `benchd` and `timeout` are shell scripts in a scratch directory
/// that write what they were asked into `calls`, so nothing here loads a launch agent or touches a
/// benchd. The real launchd path is proved by `just launchd-proof` in `daemon/`, recorded on the PR.
class BenchdAgentHarness: XCTestCase {
    var scratch: URL!

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

    var scripts: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Build
            .deletingLastPathComponent()  // HelmTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("scripts")
    }

    var bin: URL { scratch.appendingPathComponent("bin") }
    var calls: URL { scratch.appendingPathComponent("calls") }

    func recorded() -> String {
        (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
    }

    func lines(_ log: String) -> [Substring] { log.split(separator: "\n") }

    /// Fakes that record every call. `launchctl print` answers "loaded" when `loaded` exists;
    /// `kickstart` and `benchd` bump the pid `bench status` reports; `bench status` answers only
    /// while `up` exists, and `bench stop` removes it.
    func writeFakes() throws {
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
            bootstrap) touch \(state)/up ;;
            bootout) rm -f \(state)/up ;;
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
            restore) [ -e \(state)/restore-fails ] && exit 4; echo '{"restored": [{"pane": "p1", "session": "s1", "how": "resumed"}, {"pane": "p2", "session": "s2", "how": "shell"}]}' ;;
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

    func bash(
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

    func plist(suite: String?, listen: String? = nil) throws -> [String: Any] {
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
}

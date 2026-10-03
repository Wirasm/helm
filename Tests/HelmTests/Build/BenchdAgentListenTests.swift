import XCTest

/// `scripts/benchd-agent.sh`'s `--listen tailscale` (#625) and what an install does around a
/// benchd it restarts: keep the listener, bring the panes back. Against the fakes of
/// `BenchdAgentHarness`, plus a fake `tailscale` and `ifconfig`.
final class BenchdAgentListenTests: BenchdAgentHarness {
    private var install: [String] {
        [scripts.appendingPathComponent("benchd-agent.sh").path, "install", "--no-build"]
    }
    private var cargo: [String: String] { ["CARGO_INSTALL_ROOT": scratch.path] }
    private var plistPath: URL {
        scratch.appendingPathComponent("Library/LaunchAgents/com.wirasm.benchd.plist")
    }

    /// `tailscale ip -4` answering `answer` (nil: it fails as a stopped Tailscale does), and
    /// `ifconfig` listing `interfaces` as this Mac's addresses.
    private func fakeTailscale(_ answer: String?, interfaces: [String]) throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakes = [
            // macOS ships no `timeout`, and CI's runner has none: as `writeFakes` has it.
            "timeout": #"shift; exec "$@""#,
            "tailscale": answer.map { "[ \"$*\" = \"ip -4\" ] || exit 9\necho '\($0)'" }
                ?? "echo 'Tailscale is stopped.' >&2\nexit 1",
            "ifconfig": interfaces.map { "echo '\tinet \($0) netmask 0xffffffff'" }
                .joined(separator: "\n"),
        ]
        for (name, body) in fakes {
            let path = bin.appendingPathComponent(name)
            try "#!/bin/bash\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
    }

    /// `resolve_listen <spec>`: the address benchd is to listen on, or a refusal.
    private func resolve(
        _ spec: String, tailscale answer: String?, interfaces: [String] = []
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        try fakeTailscale(answer, interfaces: interfaces)
        return try bash([
            "-c", "source \"$1\"; resolve_listen \"$2\"", "test",
            scripts.appendingPathComponent("benchd-agent.sh").path, spec,
        ])
    }

    private func listen() throws -> String? {
        let agent = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: plistPath), format: nil) as? [String: Any])
        return (agent["EnvironmentVariables"] as? [String: String])?["BENCH_LISTEN"]
    }

    /// The agent's benchd listens where `--listen` said, and only then.
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

    /// The port has no login, so the tailnet is the trust boundary: `tailscale` is the Mac's
    /// tailnet address, carried by an interface here, or a refusal; never 0.0.0.0, a LAN address,
    /// or loopback in its place.
    func testListenTailscaleIsTheTailnetAddressOrARefusal() throws {
        let tailnet = try resolve(
            "tailscale", tailscale: "100.101.102.103", interfaces: ["127.0.0.1", "100.101.102.103"])
        XCTAssertEqual(tailnet.status, 0, tailnet.stderr)
        XCTAssertEqual(tailnet.stdout, "100.101.102.103:4519\n")
        let port = try resolve(
            "tailscale:5000", tailscale: "100.101.102.103", interfaces: ["100.101.102.103"])
        XCTAssertEqual(port.stdout, "100.101.102.103:5000\n", port.stderr)

        let stopped = try resolve("tailscale", tailscale: nil)
        XCTAssertNotEqual(stopped.status, 0)
        XCTAssertTrue(stopped.stderr.contains("Tailscale"), stopped.stderr)
        for lan in ["192.168.1.5", "10.0.0.7", "", "100.200.1.1"] {
            let refused = try resolve("tailscale", tailscale: lan, interfaces: [lan])
            XCTAssertNotEqual(refused.status, 0, "\(lan) was taken for a tailnet address")
            XCTAssertEqual(refused.stdout, "", lan)
        }
        // Tailscale in userspace mode delivers to no interface here: benchd could not bind it.
        let userspace = try resolve(
            "tailscale", tailscale: "100.98.232.17", interfaces: ["127.0.0.1", "192.168.1.5"])
        XCTAssertNotEqual(userspace.status, 0)
        XCTAssertEqual(userspace.stdout, "")
        XCTAssertTrue(userspace.stderr.contains("userspace"), userspace.stderr)
    }

    /// `--listen` takes the tailnet and nothing else (operator, 2026-10-03).
    func testListenTakesOnlyTailscale() throws {
        for spec in [
            "127.0.0.1:52230", "100.101.102.103:4519", "0.0.0.0:4519", "[::]:4519",
            "rasmus-mac.tail1234.ts.net:4519", "tailscale:nope", "tailscaled",
        ] {
            let refused = try resolve(
                spec, tailscale: "100.101.102.103", interfaces: ["100.101.102.103"])
            XCTAssertNotEqual(refused.status, 0, spec)
            XCTAssertEqual(refused.stdout, "", spec)
        }
    }

    /// A `--listen` that cannot be resolved, or is empty, stops the install before it builds or
    /// loads anything.
    func testAnInstallWhoseListenCannotResolveTouchesNothing() throws {
        try writeFakes()
        try fakeTailscale(nil, interfaces: [])
        for value in ["tailscale", ""] {
            let run = try bash(install + ["--listen", value], environment: cargo)
            XCTAssertNotEqual(run.status, 0, value)
            XCTAssertEqual(recorded(), "", "a refused install called launchctl, cargo or bench")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistPath.path))
    }

    /// The whole install: `--listen tailscale` listens on the tailnet address and prints the URL
    /// to type into Pocket. Installing again without `--listen`, as a release does, keeps it; only
    /// `--no-listen` stops it.
    func testAnInstallKeepsListeningUntilToldNotTo() throws {
        try writeFakes()
        try fakeTailscale("100.66.105.26", interfaces: ["127.0.0.1", "100.66.105.26"])
        let first = try bash(install + ["--listen", "tailscale"], environment: cargo)
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertTrue(
            first.stdout.contains("type tcp://100.66.105.26:4519 into Pocket"), first.stdout)
        XCTAssertEqual(try listen(), "100.66.105.26:4519")

        let release = try bash(install, environment: cargo)
        XCTAssertEqual(release.status, 0, release.stderr)
        XCTAssertEqual(try listen(), "100.66.105.26:4519", "a release keeps Pocket's listener")
        XCTAssertTrue(
            release.stdout.contains("still listens on 100.66.105.26:4519"), release.stdout)
        XCTAssertTrue(release.stdout.contains("type tcp://100.66.105.26:4519"), release.stdout)
        XCTAssertFalse(release.stderr.contains("not a tailnet address"), release.stderr)

        let stop = try bash(install + ["--no-listen"], environment: cargo)
        XCTAssertEqual(stop.status, 0, stop.stderr)
        XCTAssertNil(try listen())
        XCTAssertTrue(stop.stdout.contains("no longer listens on 100.66.105.26:4519"), stop.stdout)

        let both = try bash(install + ["--listen", "tailscale", "--no-listen"], environment: cargo)
        XCTAssertNotEqual(both.status, 0, "listen and do not listen at once is refused")
    }

    /// An address kept from before `--listen` took only the tailnet stays (a release must not cut
    /// Pocket off), and the installer says it is not one.
    func testAKeptAddressThatIsNotTheTailnetIsNamed() throws {
        try writeFakes()
        _ = try plist(suite: nil, listen: "127.0.0.1:4519")
        try FileManager.default.createDirectory(
            at: plistPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: scratch.appendingPathComponent("agent.plist"), to: plistPath)
        let release = try bash(install, environment: cargo)
        XCTAssertEqual(release.status, 0, release.stderr)
        XCTAssertEqual(try listen(), "127.0.0.1:4519")
        XCTAssertTrue(release.stderr.contains("not a tailnet address"), release.stderr)
    }

    /// An install that stopped a running benchd ended every session in it, as a release does: it
    /// brings the panes back (`bench restore --all`, what `just resume-all` runs) once the new
    /// benchd answers, and says what each got. One that started the first benchd restores nothing,
    /// and a restore that fails leaves the install done and names the way to finish.
    func testAnInstallThatRestartedBenchdBringsThePanesBack() throws {
        try writeFakes()
        let restarted = try bash(install, environment: cargo)
        XCTAssertEqual(restarted.status, 0, restarted.stderr)
        let calls = lines(recorded())
        let bootstrap = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("launchctl bootstrap") })
        let restore = try XCTUnwrap(calls.firstIndex(of: "bench restore --all"), "\(calls)")
        XCTAssertGreaterThan(restore, bootstrap, "restored once the new benchd is up")
        XCTAssertTrue(restarted.stdout.contains("restored 2 panes"), restarted.stdout)
        XCTAssertTrue(restarted.stdout.contains("p1: resumed"), restarted.stdout)

        // The agent is loaded now; reinstalling reloads it, and this restore fails.
        FileManager.default.createFile(
            atPath: scratch.appendingPathComponent("loaded").path, contents: nil)
        FileManager.default.createFile(
            atPath: scratch.appendingPathComponent("restore-fails").path, contents: nil)
        try "".write(to: self.calls, atomically: true, encoding: .utf8)
        let reloaded = try bash(install, environment: cargo)
        XCTAssertEqual(reloaded.status, 0, "benchd is up: the install is done\n\(reloaded.stderr)")
        XCTAssertTrue(lines(recorded()).contains("bench restore --all"), recorded())
        XCTAssertTrue(reloaded.stderr.contains("just resume-all"), reloaded.stderr)

        // Nothing was running: nothing ended, nothing to restore.
        try FileManager.default.removeItem(at: scratch.appendingPathComponent("loaded"))
        try FileManager.default.removeItem(at: scratch.appendingPathComponent("up"))
        try "".write(to: self.calls, atomically: true, encoding: .utf8)
        let fresh = try bash(install, environment: cargo)
        XCTAssertEqual(fresh.status, 0, fresh.stderr)
        XCTAssertFalse(lines(recorded()).contains("bench restore --all"), recorded())
    }
}

import XCTest

@testable import Helm

final class ArchonCLITests: XCTestCase {
    private var root: URL!
    private var bin: URL!
    private var captures: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helm-archon-cli-tests-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        captures = root.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func install(_ body: String) throws {
        let script = bin.appendingPathComponent("archon")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    private func cli(extraEnvironment: [String: String] = [:]) -> ArchonCLI {
        var environment = extraEnvironment
        environment["PATH"] = bin.path
        return ArchonCLI(
            inheritedEnvironment: environment,
            homeDirectory: root.appendingPathComponent("home").path,
            captureDirectory: captures)
    }

    func testStatusUsesDevelopmentPathExactArgumentsAndDeletesCapture() async throws {
        let pathRecord = root.appendingPathComponent("path")
        let argsRecord = root.appendingPathComponent("args")
        try install(
            "printf '%s' \"$PATH\" > \"$PATH_RECORD\"\nprintf '%s\\n' \"$@\" > \"$ARGS_RECORD\"\nprintf '{\"runs\":[]}'\n"
        )

        let runs = try await cli(extraEnvironment: [
            "PATH_RECORD": pathRecord.path, "ARGS_RECORD": argsRecord.path,
        ]).activeRuns()

        XCTAssertEqual(runs, [])
        let path = try String(contentsOf: pathRecord, encoding: .utf8)
        XCTAssertTrue(path.hasPrefix(root.appendingPathComponent("home/.bun/bin").path + ":"))
        XCTAssertEqual(
            try String(contentsOf: argsRecord, encoding: .utf8),
            "workflow\nstatus\n--json\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: captures.path), [])
    }

    func testListGetAndLaunchComposePublishedArguments() async throws {
        let argsRecord = root.appendingPathComponent("args")
        try install(
            "printf '%s\\n' \"$@\" > \"$ARGS_RECORD\"\ncase \"$2\" in list) printf '{\"workflows\":[],\"errors\":[]}' ;; get) printf '{\"id\":\"r1\",\"workflow_name\":\"ship\",\"status\":\"running\",\"nodes\":[]}' ;; run) printf '{\"ok\":true,\"action\":\"run\",\"detached\":true,\"workflow\":\"ship\",\"branch\":\"b\",\"conversationId\":\"c\",\"logPath\":null}' ;; esac\n"
        )
        let client = cli(extraEnvironment: ["ARGS_RECORD": argsRecord.path])

        _ = try await client.workflows(in: "/tmp/project")
        XCTAssertEqual(
            try String(contentsOf: argsRecord), "workflow\nlist\n--json\n--cwd\n/tmp/project\n")
        _ = try await client.run(id: "r1")
        XCTAssertEqual(try String(contentsOf: argsRecord), "workflow\nget\nr1\n--json\n--verbose\n")
        _ = try await client.launch(
            .init(
                workspacePath: "/tmp/project", workflow: "ship", input: "do it", branch: "b",
                noWorktree: false))
        XCTAssertEqual(
            try String(contentsOf: argsRecord),
            "workflow\nrun\nship\ndo it\n--detach\n--json\n--cwd\n/tmp/project\n--branch\nb\n")
    }

    func testNonzeroEmptyAndMalformedOutputAreDistinctAndCleanedUp() async throws {
        try install("exit 7\n")
        do { _ = try await cli().activeRuns(); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? ArchonCLIError, .nonzeroExit(7))
        }

        try install("exit 0\n")
        do { _ = try await cli().activeRuns(); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? ArchonCLIError, .emptyOutput)
        }

        try install("printf 'not json'\n")
        do { _ = try await cli().activeRuns(); XCTFail("expected failure") } catch {
            if case .malformedJSON = error as? ArchonCLIError {
            } else {
                XCTFail("wrong error: \(error)")
            }
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: captures.path), [])
    }
}

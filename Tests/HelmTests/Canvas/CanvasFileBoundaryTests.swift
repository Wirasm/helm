import XCTest

@testable import Helm

/// The artifact's directory is what a canvas may read. These run against a real directory
/// tree with a real symlink in it, because the bug this file exists to prevent is exactly
/// the one a string-only test cannot see.
final class CanvasFileBoundaryTests: XCTestCase {
    private var root: URL!
    private var artifacts: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-boundary-\(UUID().uuidString)")
        artifacts = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try "sibling".write(
            to: artifacts.appendingPathComponent("diagram.css"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: artifacts.appendingPathComponent("img"), withIntermediateDirectories: true)
        try "nested".write(
            to: artifacts.appendingPathComponent("img/x.png"), atomically: true, encoding: .utf8)
        try "secret".write(
            to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func resolve(_ request: String) -> URL? {
        CanvasFileBoundary.resolve(request: request, inDirectory: artifacts)
    }

    // MARK: - What a page may read

    func testASiblingResolves() throws {
        let file = try XCTUnwrap(resolve("/diagram.css"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "sibling")
    }

    func testANestedFileResolves() throws {
        let file = try XCTUnwrap(resolve("/img/x.png"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "nested")
    }

    // MARK: - What it may not

    func testATraversalOutOfTheDirectoryIsRefused() {
        XCTAssertNil(resolve("/../outside.txt"))
        XCTAssertNil(resolve("/img/../../outside.txt"))
        XCTAssertNil(resolve("/../../../../etc/passwd"))
    }

    func testASymlinkPointingOutOfTheDirectoryIsRefused() throws {
        // The case a string-only check cannot catch: `standardizedFileURL` collapses `..`
        // lexically and never asks the filesystem anything, so the candidate's *string*
        // sits safely inside the directory — and `Data(contentsOf:)` then follows the link
        // straight out of it. Found in review of #164, before it shipped.
        try FileManager.default.createSymbolicLink(
            at: artifacts.appendingPathComponent("escape.txt"),
            withDestinationURL: root.appendingPathComponent("outside.txt"))

        XCTAssertNil(
            resolve("/escape.txt"),
            "a containment check that reasons only about strings is not a containment check")
    }

    func testASymlinkedDirectoryInsideIsAlsoRefused() throws {
        try FileManager.default.createSymbolicLink(
            at: artifacts.appendingPathComponent("out"), withDestinationURL: root)

        XCTAssertNil(resolve("/out/outside.txt"))
    }

    func testASiblingDirectorySharingAPrefixIsNotInside() throws {
        // `/tmp/x/artifacts` must not be judged to contain `/tmp/x/artifacts-evil/…`.
        let evil = root.appendingPathComponent("artifacts-evil")
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        try "nope".write(
            to: evil.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        XCTAssertNil(resolve("/../artifacts-evil/secret.txt"))
    }

    func testAnEmptyRequestIsRefusedRatherThanResolvingToTheDirectory() {
        XCTAssertNil(resolve("/"))
        XCTAssertNil(resolve(""))
    }

    // MARK: - A symlinked root still works

    func testTheDirectoryItselfMaySitUnderASymlink() throws {
        // On macOS the root routinely does — /tmp is a symlink to /private/tmp. Resolving
        // the candidate but not the root would refuse every legitimate sibling.
        let link = root.appendingPathComponent("link-to-artifacts")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: artifacts)

        let file = try XCTUnwrap(
            CanvasFileBoundary.resolve(request: "/diagram.css", inDirectory: link))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "sibling")
    }
}

import CanvasKit
import Foundation
import HelmWire

@testable import Helm

/// A canvas's files on this test's own disk, with benchd's rules (`benchd/src/files.rs`): a read
/// confined to a folder answers `outside` for `..` and for a symlink out of it; a write expecting
/// `unchanged` bytes writes only over those bytes or nothing; a sidecar is never written whole.
///
/// **A stand-in, not a spec.** What benchd does is pinned by the daemon gate's conformance tests
/// over TCP; this lets a canvas test run without a benchd. `failing` makes every call fail the
/// way an unreachable benchd does.
struct DiskCanvasFiles: CanvasFiles {
    var failing: String?

    func read(_ path: String, within folder: String?) -> CanvasFileRead {
        if let failing { return .failed(failing) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let folder, !Self.inside(url, URL(fileURLWithPath: folder).standardizedFileURL) {
            return .outside
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .absent
        }
        guard !isDirectory.boolValue, let data = try? Data(contentsOf: url) else {
            return .failed("cannot read \(url.path)")
        }
        return .bytes(data)
    }

    /// `notify` is benchd's to act on (the live file's mail); the disk has nobody to tell.
    func write(
        _ text: String, to path: String, expect: BenchFileExpect, notify: Bool
    )
        -> CanvasFileWrite
    {
        if let failing { return .failed(failing) }
        let url = URL(fileURLWithPath: path)
        if CanvasNotes.isSidecar(url) { return .failed("\(path) is a notes sidecar") }
        let expected: String
        switch expect {
        case let .unchanged(text): expected = text
        }
        switch read(path, within: nil) {
        case let .bytes(now) where now != Data(expected.utf8): return .changed(now)
        case .bytes, .absent: break
        case .outside: return .failed("outside")
        case let .failed(why): return .failed(why)
        }
        if case .bytes(Data(text.utf8)) = read(path, within: nil) { return .written }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return .written
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func append(_ text: String, to path: String) throws {
        if let failing { throw CanvasFileFailure(reason: failing) }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    /// Lexically, then with symlinks followed for a file that exists.
    private static func inside(_ file: URL, _ folder: URL) -> Bool {
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        guard file.path.hasPrefix(prefix) else { return false }
        guard FileManager.default.fileExists(atPath: file.path) else { return true }
        let root = folder.resolvingSymlinksInPath().path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        return file.resolvingSymlinksInPath().path.hasPrefix(rootPrefix)
    }
}

extension CanvasModel {
    /// A canvas over this test's own disk.
    convenience init(source: CanvasSource? = nil, saveDebounce: Duration = .milliseconds(600)) {
        self.init(source: source, files: DiskCanvasFiles(), saveDebounce: saveDebounce)
    }
}

extension FakeBenchd {
    /// Answer `file/*` from `files` — this test's disk — and everything else as `other` does.
    /// benchd's own answers are the daemon gate's; this keeps helm's side of the wire honest.
    func answeringFiles(
        with files: DiskCanvasFiles = DiskCanvasFiles(),
        else other: @escaping @Sendable ([String: Any]) -> [String: Any]
    ) -> @Sendable ([String: Any]) -> [String: Any] {
        { raw in
            let id = raw["id"] ?? ""
            let args = raw["args"] as? [String: Any] ?? [:]
            let path = args["path"] as? String ?? ""
            func refused(_ why: String) -> [String: Any] {
                ["id": id, "status": "refused", "reason": why]
            }
            func ok(_ data: [String: Any]) -> [String: Any] {
                ["id": id, "status": "ok", "data": data]
            }
            switch raw["verb"] as? String {
            case "file/read":
                switch files.read(path, within: args["within"] as? String) {
                case let .bytes(data):
                    return ok(["kind": "bytes", "base64": data.base64EncodedString()])
                case .absent: return ok(["kind": "absent"])
                case .outside: return ok(["kind": "outside"])
                case let .failed(why): return refused(why)
                }
            case "file/write":
                let expect = args["expect"] as? [String: Any] ?? [:]
                guard expect["kind"] as? String == "unchanged" else {
                    return refused("file/write args: expect must be unchanged")
                }
                switch files.write(
                    args["text"] as? String ?? "", to: path,
                    expect: .unchanged(expect["text"] as? String ?? ""),
                    notify: args["notify"] as? Bool ?? false)
                {
                case .written: return ok(["kind": "written"])
                case let .changed(now):
                    return ok(["kind": "changed", "base64": now.base64EncodedString()])
                case let .failed(why): return refused(why)
                }
            case "file/append":
                do {
                    try files.append(args["text"] as? String ?? "", to: path)
                    return ok([:])
                } catch {
                    return refused(error.localizedDescription)
                }
            default:
                return other(raw)
            }
        }
    }
}

/// The frame benchd's follower carries when a canvas file settled into a new state.
func fileChangedFrame(_ path: String, seq: Int = 900) -> Data {
    let frame: [String: Any] = [
        "event": [
            "seq": seq, "at": "2026-09-28T12:00:00Z", "kind": "file/changed",
            "data": ["path": path],
        ]
    ]
    return try! JSONSerialization.data(withJSONObject: frame)
}

// The sidecar on this test's disk, for the tests written before benchd held it.
extension CanvasNotes {
    static func append(_ annotation: CanvasAnnotation, for canvas: URL, at timestamp: Date) throws {
        try append(annotation, for: canvas, at: timestamp, through: DiskCanvasFiles())
    }

    static func markdown(in sidecar: URL) -> String? {
        markdown(in: sidecar, through: DiskCanvasFiles())
    }
}

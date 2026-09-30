import Foundation
import HelmWire
import XCTest

@testable import Helm

/// benchd's prp verbs and `path/resolve` over a temporary directory, for a test of helm's side.
///
/// **A toy, not benchd's rules.** A store is a directory holding `project.json`; a workspace's
/// store key is its folder's name (`key`), not prp's resolver; a note is created as benchd creates
/// it. The real rules — the canonical resolver, the walk, `~` against benchd's home — are the
/// daemon gate's, over TCP against the real binary.
final class FakePrp: @unchecked Sendable {
    /// Stands in for benchd's `~/.prp`.
    let root: URL
    /// What `~` means on "benchd's machine".
    let home: URL
    /// When set, every verb here is refused with it.
    var refusing: String?

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-fake-prp-\(UUID().uuidString)")
        root = base.appendingPathComponent("prp")
        home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// The toy's store key for a workspace.
    func key(_ workspace: String) -> String { (workspace as NSString).lastPathComponent }

    @discardableResult
    func store(_ key: String, path: String?, name: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fields: [String: String] = [:]
        fields["path"] = path
        fields["name"] = name
        try JSONSerialization.data(withJSONObject: fields)
            .write(to: dir.appendingPathComponent("project.json"))
        return dir
    }

    /// The answer to `raw` when it is one of this toy's verbs; nil otherwise.
    func answer(_ raw: [String: Any]) -> [String: Any]? {
        let verb = raw["verb"] as? String ?? ""
        guard verb.hasPrefix("prp/") || verb == "path/resolve" else { return nil }
        let id = raw["id"] ?? ""
        if let refusing { return ["id": id, "status": "refused", "reason": refusing] }
        let args = raw["args"] as? [String: Any] ?? [:]
        do {
            return ["id": id, "status": "ok", "data": try data(verb, args)]
        } catch {
            return ["id": id, "status": "refused", "reason": "\(error)"]
        }
    }

    private struct Refusal: Error, CustomStringConvertible { let description: String }

    private func data(_ verb: String, _ args: [String: Any]) throws -> [String: Any] {
        let fm = FileManager.default
        switch verb {
        case "prp/note":
            let workspace = args["workspace"] as? String ?? ""
            let day = args["day"] as? String ?? ""
            let notes = root.appendingPathComponent(key(workspace)).appendingPathComponent("notes")
            try fm.createDirectory(at: notes, withIntermediateDirectories: true)
            var n = 1
            while true {
                let name = n == 1 ? "\(day)-note.md" : "\(day)-note-\(n).md"
                let path = notes.appendingPathComponent(name).path
                if !fm.fileExists(atPath: path), fm.createFile(atPath: path, contents: nil) {
                    return ["path": path]
                }
                n += 1
            }
        case "prp/stores":
            let stores = try listStores()
            var data: [String: Any] = ["stores": stores]
            if let workspace = args["workspace"] as? String,
                stores.contains(where: { $0["key"] as? String == key(workspace) })
            {
                data["workspace"] = key(workspace)
            }
            return data
        case "prp/artifacts":
            let store = args["store"] as? String ?? ""
            guard try listStores().contains(where: { $0["key"] as? String == store }) else {
                throw Refusal(description: "no prp store \"\(store)\"")
            }
            return ["files": artifacts(in: root.appendingPathComponent(store))]
        default:
            return try resolve(args["path"] as? String ?? "")
        }
    }

    private func listStores() throws -> [[String: Any]] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(atPath: root.path).sorted().compactMap { key in
            let json = root.appendingPathComponent(key).appendingPathComponent("project.json")
            guard let data = fm.contents(atPath: json.path) else { return nil }
            let fields = try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
            var store: [String: Any] = [
                "key": key, "name": fields["name"] ?? key,
                "dir": root.appendingPathComponent(key).path,
            ]
            store["path"] = fields["path"]
            return store
        }
    }

    private func artifacts(in store: URL) -> [[String: Any]] {
        let walk = FileManager.default.enumerator(
            at: store, includingPropertiesForKeys: [.contentModificationDateKey])
        let files = (walk?.allObjects as? [URL] ?? []).filter(RenderableFile.isRenderable)
        let base = store.resolvingSymlinksInPath().path
        func modified(_ url: URL) -> Double {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        let newestFirst = files.sorted { modified($0) > modified($1) }
        return newestFirst.map { url -> [String: Any] in
            let path = url.resolvingSymlinksInPath().path
            return [
                "path": path,
                "relative": String(path.dropFirst(base.count + 1)),
                "modified_ms": Int(modified(url) * 1000),
            ]
        }
    }

    private func resolve(_ typed: String) throws -> [String: Any] {
        let expanded =
            typed == "~" || typed.hasPrefix("~/") ? home.path + typed.dropFirst() : typed
        guard expanded.hasPrefix("/") else {
            throw Refusal(description: "not an absolute path: \(typed)")
        }
        let path = (expanded as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw Refusal(description: "nothing at \(path)")
        }
        return ["path": path, "kind": isDirectory.boolValue ? "directory" : "file"]
    }
}

extension FakeBenchd {
    /// Answer `prp/*` and `path/resolve` from `prp`, and everything else as `other` does.
    func answeringPrp(
        _ prp: FakePrp, else other: @escaping @Sendable ([String: Any]) -> [String: Any]
    ) -> @Sendable ([String: Any]) -> [String: Any] {
        { raw in prp.answer(raw) ?? other(raw) }
    }
}

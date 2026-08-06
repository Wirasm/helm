import Foundation

/// The private, per-instance file boundary for the agent-readable bench snapshot.
struct BenchSnapshotDirectory: Equatable {
    static let directoryVariable = "HELM_BENCH_DIR"

    let root: URL

    var snapshot: URL { root.appendingPathComponent("snapshot.json") }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> BenchSnapshotDirectory {
        if let raw = environment[directoryVariable]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            return BenchSnapshotDirectory(
                root: URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
        let base = home.appendingPathComponent(".helm")
        switch DefaultsDomain.override(in: environment) {
        case .suite(let name):
            return BenchSnapshotDirectory(root: base.appendingPathComponent("bench-\(name)"))
        case .none, .refused:
            return BenchSnapshotDirectory(root: base.appendingPathComponent("bench"))
        }
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    @discardableResult
    func write(_ value: BenchSnapshot) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return false }
        do {
            try data.write(to: snapshot, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
            return true
        } catch {
            NSLog(
                "helm: could not write bench snapshot at %@: %@",
                snapshot.path, String(describing: error))
            return false
        }
    }

    func read() -> BenchSnapshot? {
        guard let data = try? Data(contentsOf: snapshot) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BenchSnapshot.self, from: data)
    }
}

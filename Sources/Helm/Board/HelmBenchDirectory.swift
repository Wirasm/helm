import Foundation

/// helm's own private, per-instance directory: `~/.helm/bench`, `~/.helm/bench-<suite>` under
/// `HELM_DEFAULTS_SUITE`, or `HELM_BENCH_DIR`. It holds the agent-readable bench snapshot and the
/// operator's keymap: things of helm's that stay on helm's machine when benchd is on another
/// (M5c), which is why neither lives under the bench root.
struct HelmBenchDirectory: Equatable {
    static let directoryVariable = "HELM_BENCH_DIR"

    let root: URL

    var snapshot: URL { root.appendingPathComponent("snapshot.json") }
    /// The operator's keymap (`Keymap`). helm reads it and nothing writes it.
    var keymap: URL { root.appendingPathComponent("keymap.toml") }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> HelmBenchDirectory {
        if let raw = environment[directoryVariable]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            return HelmBenchDirectory(
                root: URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
        let base = home.appendingPathComponent(".helm")
        switch DefaultsDomain.override(in: environment) {
        case .suite(let name):
            return HelmBenchDirectory(root: base.appendingPathComponent("bench-\(name)"))
        case .none, .refused:
            return HelmBenchDirectory(root: base.appendingPathComponent("bench"))
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

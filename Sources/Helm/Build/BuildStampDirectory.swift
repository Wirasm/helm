import Foundation

/// Where the build stamp lives, and the one place that reads it.
///
/// **One location, no suite variant, and that is a decision rather than an omission.** The
/// bench snapshot gets a `bench-<suite>` directory because a bench is per-instance — two
/// helms have two different sets of panes. A *build* is not per-instance: there is one
/// Release product on this machine at a time, and an isolated worktree instance builds the
/// same repo. Splitting the stamp per suite would mean a worktree helm comparing itself
/// against a stamp nothing ever writes, which is a badge that can never appear.
///
/// The question a suite really raises — *should a worktree test instance offer to replace the
/// operator's application?* — is a policy question, and it is answered as one in
/// `BuildUpdateModel`, not by hiding the file from it.
struct BuildStampDirectory: Equatable {
    /// The escape hatch a test needs: this type otherwise resolves to the operator's own
    /// `~/.helm/build`, and a test does not get to write there.
    static let directoryVariable = "HELM_BUILD_DIR"

    let root: URL

    var latest: URL { root.appendingPathComponent("latest.json") }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> BuildStampDirectory {
        if let raw = environment[directoryVariable]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            return BuildStampDirectory(
                root: URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
        return BuildStampDirectory(
            root: home.appendingPathComponent(".helm").appendingPathComponent("build"))
    }

    /// The stamp on disk, or nil — where nil covers "no build has run", "the file is being
    /// rewritten underneath us", and "this helm does not understand that format" alike.
    ///
    /// **Collapsing those into one nil is deliberate.** Every one of them means the same
    /// thing to the only caller: say nothing. A badge is an offer to replace the running
    /// application, and there is no version of a half-read stamp that should produce one.
    func read() -> BuildStamp? {
        guard let data = try? Data(contentsOf: latest) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stamp = try? decoder.decode(BuildStamp.self, from: data), stamp.isReadable
        else { return nil }
        return stamp
    }
}

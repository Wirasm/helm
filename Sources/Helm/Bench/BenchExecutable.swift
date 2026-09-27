import Foundation

/// Which `bench` helm runs to show a benchd session in a pane (`SessionAttach`), always as an
/// absolute path.
///
/// A pane's command runs through a login shell started with no profile (`/usr/bin/login -flp
/// <user> /bin/bash --noprofile --norc -c 'exec -l …'`), so its PATH is the system's and has no
/// `~/.cargo/bin`, where `cargo install` puts `bench`. A bare `bench` therefore fails in the pane
/// with "exec: bench: not found" whenever benchd did not name its own copy — which is what helm
/// used to fall back to.
///
/// In order: the `bench` benchd names in `status` (the one beside it, so its own build), then the
/// places a `bench` is installed, then helm's own PATH. When none exists the answer is the reason,
/// which the pane shows instead of starting anything.
enum BenchExecutable {
    /// Where `cargo install` and Homebrew put binaries, before helm's own PATH.
    static func candidates(home: String, path: String?) -> [String] {
        let installed = ["\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let onPath = (path ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (installed + onPath)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            .map { "\($0)/bench" }
    }

    /// The `bench` to run, or why there is none.
    ///
    /// - Parameters:
    ///   - named: what benchd's `status` said, or nil when it could not be asked.
    ///   - why: why benchd could not be asked, for the reason.
    static func resolve(
        named: String?, why: String?,
        home: String = NSHomeDirectory(),
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Result<String, NotFound> {
        if let named, named.hasPrefix("/"), isExecutable(named) { return .success(named) }
        let looked = candidates(home: home, path: path)
        if let found = looked.first(where: isExecutable) { return .success(found) }
        let asked =
            named.map { "benchd named \($0), which is not an executable here" }
            ?? "benchd could not be asked (\(why ?? "no answer"))"
        return .failure(NotFound(asked: asked, looked: looked))
    }

    /// No `bench` to run: what was tried, and the fix.
    struct NotFound: Error, Equatable {
        let asked: String
        let looked: [String]

        var description: String {
            "helm cannot find the bench CLI to show this session: \(asked), and none of "
                + "\(looked.joined(separator: ", ")) exists. Install it with `cargo install "
                + "--path daemon/crates/bench` from the helm checkout (or `just benchd-install`), "
                + "then close this pane and reopen it."
        }
    }
}

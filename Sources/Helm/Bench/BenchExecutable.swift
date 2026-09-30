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
/// places a `bench` is installed, then helm's own PATH. A benchd reached over TCP is not asked:
/// its `bench` is on its own machine (`local`). When none exists the answer is the reason,
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

    /// An installed `bench`, for a benchd reached over TCP (M5c): the one beside it is a path on
    /// its own machine, so benchd is not asked.
    static func local(
        home: String = NSHomeDirectory(),
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Result<String, NotFound> {
        let looked = candidates(home: home, path: path)
        if let found = looked.first(where: isExecutable) { return .success(found) }
        return .failure(
            NotFound(
                asked: "benchd is reached over TCP, so its own bench is not here", looked: looked))
    }

    /// Why a pane cannot run a `bench`: there is none, or helm's own is another build than the
    /// benchd over TCP it would talk to. Its `description` is what the pane says.
    enum Unusable: Error, Equatable {
        case notFound(NotFound)
        case otherBuild(OtherBuild)

        var description: String {
            switch self {
            case let .notFound(missing): missing.description
            case let .otherBuild(other): other.description
            }
        }
    }

    /// helm's own `bench` says another version than benchd's `status.version` (M5c): a pane
    /// running it could not be trusted to attach, so it says so rather than try.
    struct OtherBuild: Error, Equatable {
        let bench: String
        /// What `bench --version` printed; nil when it printed nothing, which is a `bench` from
        /// before the flag existed.
        let ours: String?
        let benchd: String

        /// nil when `ours` is `benchd`: the same build, nothing to say.
        init?(bench: String, ours: String?, benchd: String) {
            guard ours != benchd else { return nil }
            self.bench = bench
            self.ours = ours
            self.benchd = benchd
        }

        var description: String {
            "helm's bench (\(bench)) is version \(ours ?? "unknown"), and the benchd it reaches over "
                + "TCP is version \(benchd). Install the same build on both machines (`just "
                + "benchd-install`, or `cargo install --path daemon/crates/bench` here), then close "
                + "this pane and reopen it."
        }
    }

    /// The version a `bench` says it is (`bench --version`), or nil when it says none: it is
    /// older than the flag, cannot run, or took longer than two seconds.
    static func version(of bench: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bench)
        process.arguments = ["--version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let printed = String(
            decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return printed.isEmpty ? nil : printed
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

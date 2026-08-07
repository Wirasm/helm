import Foundation

/// The spool on disk: where requests arrive, where claimed ones go to die, and where results
/// are written.
///
/// ```
/// ~/.helm/spool/            <id>.json          a request, waiting
/// ~/.helm/spool/claimed/    <id>.json          claimed — never read again
/// ~/.helm/spool/results/    <id>.json          what helm did about it
/// ~/.helm/spool/prompts/    <id>.txt           the prompt, 0600, read by the AGENT (#93)
/// ~/.helm/spool/captures/   <id>.png           helm's own window, drawn on request (#174)
/// ```
///
/// **A second helm must not eat the operator's requests.** Two helms is the *normal* state
/// while building helm, and `AGENTS.md` makes an isolated instance's defaults suite the way to
/// keep them apart. The spool is state of exactly that kind — a worktree build watching
/// `~/.helm/spool` would claim a request meant for the operator's helm and open the terminal
/// in the wrong window, which is the disaster `HELM_DEFAULTS_SUITE` exists to prevent, one
/// directory over. So the suite moves the spool too, automatically, rather than by
/// remembering: `HELM_DEFAULTS_SUITE=helm-bench` watches `~/.helm/spool-helm-bench`.
///
/// **Lives in `HelmWire` (#221)** — `Helm`'s own `SpoolModel` and `SpoolWatcher` resolve their
/// spool through this rather than restating it. `resolve` is also "the three resolution rules a
/// CLI must not guess at" that `AGENTS.md` documents for `tools/helm-spool.swift`,
/// `helm-close.swift` and `helm-capture.swift` — those three cannot `import HelmWire` (see
/// `AGENTS.md`'s "Why the spool is a script, and must stay one") and so still reimplement this
/// exact function by hand, each carrying a comment pointing back here for the reasoning.
package struct SpoolDirectory: Equatable {
    /// Points helm's spool somewhere else outright. For tests, and for a caller that wants to
    /// address one specific instance. Mirrors `HELM_MAIL_DIR`, which the mail hooks honour.
    package static let directoryVariable = "HELM_SPOOL_DIR"

    /// Switches the watcher off without switching helm off. The negative control for every
    /// claim this slice makes: with this set, a request must produce no terminal and no
    /// result. Mirrors `HELM_MAIL_OFF`.
    package static let offVariable = "HELM_SPOOL_OFF"

    package let root: URL

    package var claimed: URL { root.appendingPathComponent("claimed") }
    package var results: URL { root.appendingPathComponent("results") }
    package var prompts: URL { root.appendingPathComponent("prompts") }
    package var captures: URL { root.appendingPathComponent("captures") }

    package init(root: URL) {
        self.root = root
    }

    /// Where this process's spool is, from its environment alone. Pure, so the isolation rule
    /// above is a test rather than a claim.
    package static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SpoolDirectory {
        if let raw = environment[directoryVariable]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            return SpoolDirectory(
                root: URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
        let base = home.appendingPathComponent(".helm")
        // The same parser the defaults domain uses, so there is one answer to "is this the
        // operator's helm?" rather than two that can drift. `.refused` never gets this far in
        // a running helm — `DefaultsDomain.resolve` stops the launch — and falling back to the
        // shared spool for it would be the silent-isolation bug rebuilt, so it is spelled out.
        // A standalone CLI has no launch to stop, so it treats `.refused` the same as `.none`
        // — see `DefaultsSuite.Override.refused`.
        switch DefaultsSuite.override(in: environment) {
        case .suite(let name):
            return SpoolDirectory(root: base.appendingPathComponent("spool-\(name)"))
        case .none, .refused:
            return SpoolDirectory(root: base.appendingPathComponent("spool"))
        }
    }

    package static func isOff(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[offVariable] else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Make the five directories. 0700 throughout: a request is a command to run, a prompt is
    /// the operator's words and a capture is a picture of what they are looking at, and none of
    /// those is anyone else's business on a shared machine.
    package func prepare() throws {
        for directory in [root, claimed, results, prompts, captures] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    /// Requests waiting, oldest name first. Only the top level: `claimed/`, `results/` and
    /// `prompts/` are directories and are skipped by the extension test.
    package func pending() -> [URL] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return entries.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    /// Take a request, or discover that somebody else already did.
    ///
    /// **Claim by rename, not delete-then-act.** `rename(2)` is atomic, so of two helms — or
    /// two windows of one helm — exactly one gets a zero back and the other gets `ENOENT`.
    /// Delete-then-act would work equally well for the race and lose the payload: the claimed
    /// file is what lets a crash mid-spawn be *named* on the next launch instead of vanishing.
    ///
    /// Nothing ever reads `claimed/` back as work. That is the other half of exactly-once, and
    /// the half a restart tests: re-running a claimed request after a crash is the double-open
    /// #54 forbids, so the graveyard is a graveyard.
    package func claim(_ request: URL) -> URL? {
        let destination = claimed.appendingPathComponent(request.lastPathComponent)
        guard rename(request.path, destination.path) == 0 else { return nil }
        return destination
    }

    package func request(at url: URL) -> SpoolRequest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpoolRequest.self, from: data)
    }

    /// Write the result, atomically, so a caller watching the file never reads half of one.
    @discardableResult
    package func write(_ result: SpoolResult) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result) else { return false }
        let destination = results.appendingPathComponent("\(result.id).json")
        do {
            try data.write(to: destination, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return true
        } catch {
            NSLog("helm: could not write spool result %@: %@", result.id, String(describing: error))
            return false
        }
    }

    package func result(id: String) -> SpoolResult? {
        let url = results.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpoolResult.self, from: data)
    }

    /// Stage a prompt where the **agent** can read it. 0600, and written before anything is
    /// sent to the pty so a write failure costs a refusal rather than a half-typed line.
    ///
    /// **Nothing deletes this, and that is now load-bearing (#93).** The launch line hands the
    /// agent this path rather than the prompt, so the file is read after the pane exists, after
    /// the agent boots, on its first turn — long after helm has written the result and stopped
    /// thinking about the request. A cleanup pass over `prompts/` would have to prove the agent
    /// had already read it, which nothing here can see; the honest bound is that these are small
    /// text files in a `0700` directory the operator owns.
    package func stagePrompt(_ text: String, for id: String) -> String? {
        let url = prompts.appendingPathComponent("\(id).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        } catch {
            NSLog("helm: could not stage spool prompt %@: %@", id, String(describing: error))
            return nil
        }
    }

    /// Requests that were claimed and never answered — helm stopped between the rename and the
    /// result. Returns their ids so the caller can be told, which is the alternative to leaving
    /// it waiting on a file that is never coming.
    package func abandoned() -> [String] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: claimed, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return
            entries
            .filter { $0.pathExtension == "json" }
            .compactMap { request(at: $0)?.id }
            .filter { result(id: $0) == nil }
            .sorted()
    }
}

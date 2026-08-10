import Foundation

/// Which commit the running helm was built from.
///
/// **Stamped into the bundle at build time, by `scripts/stamp-build.sh`.** It has to be baked
/// rather than derived: an installed helm in `/Applications` has no checkout to ask, and the
/// tempting proxy — compare the bundle's modification date against the stamp's `builtAt` — is
/// a proxy rather than the thing. `cp -R` does not preserve mtimes, so the installed bundle's
/// date is the date it was *copied*, which answers a different question and answers it wrong
/// on any machine where those two differ.
enum RunningBuild {
    /// The Info.plist key the stamping script writes. Named here and in that script, and
    /// nowhere else — `BuildStampScriptTests` is what keeps the two spellings honest.
    static let shaKey = "HelmBuildSHA"

    /// This bundle's commit, or nil when nothing stamped it.
    ///
    /// **Nil is the normal state on the SPM path.** `swift run helm` builds no bundle and runs
    /// no stamping phase, so an iterating developer has no identity — and `BuildUpdate` turns
    /// that into silence rather than a badge, for the reason recorded there.
    static var sha: String? {
        resolve(bundle: .main)
    }

    static func resolve(bundle: Bundle) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: shaKey) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Whether a newer build is waiting, and which one.
///
/// **The whole decision, as a pure function over two values**, so the interesting cases are
/// reachable by a test rather than only by rebuilding the application. Everything that polls,
/// draws or relaunches is downstream of this.
enum BuildUpdate: Equatable {
    case upToDate
    case available(BuildStamp)

    /// The stamp to offer, or nil when there is nothing to say.
    var waiting: BuildStamp? {
        switch self {
        case .upToDate: nil
        case .available(let stamp): stamp
        }
    }

    /// **Four ways to say nothing, one way to speak.**
    ///
    /// - No stamp on disk: no build has been announced. Silence.
    /// - No sha on the running build: the SPM path, or a bundle built before stamping
    ///   existed. **Silence, and this is the load-bearing one** — a helm that cannot know its
    ///   own identity would otherwise badge against every stamp forever, and clicking it
    ///   would install a build it has no way to tell apart from the one already running. A
    ///   badge that cannot clear is worse than no badge.
    /// - Same sha: the running build *is* the announced one. This is what makes the badge
    ///   self-clearing — after a relaunch the new bundle's sha matches the stamp that
    ///   prompted it, with nothing to delete and no state to reset.
    /// - Anything else: a different commit is built and waiting.
    ///
    /// Note what is deliberately *not* here: no ordering, no "is it newer". helm does not
    /// know whether a sha is ahead of or behind its own — that needs the checkout, which an
    /// installed app does not have. Different is the honest question, and it is also the
    /// useful one: an agent building an older branch to test something has produced a build
    /// worth offering too.
    static func decide(running: String?, waiting: BuildStamp?) -> BuildUpdate {
        guard let waiting, waiting.isReadable else { return .upToDate }
        guard let running, !running.isEmpty else { return .upToDate }
        return waiting.sha == running ? .upToDate : .available(waiting)
    }
}

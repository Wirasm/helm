import Foundation
import HelmWire

/// The one `UserDefaults` domain helm persists to, and the one-time move of what the other
/// one had accumulated.
///
/// `UserDefaults.standard` resolves to `Bundle.main.bundleIdentifier`, falling back to the
/// process name when there is none. That gave helm two domains rather than one: `make app`
/// wrote to `com.wirasm.helm`, and `swift run helm` — a bare Mach-O with no Info.plist —
/// wrote to `helm`. Same code, same keys, different files, and nothing in the app said so.
/// The cost is in #45: a restore bug was diagnosed against the domain the running build was
/// not using, and a split like that does not produce a wrong answer, it produces a
/// plausible one.
///
/// **The fix is not in this file.** `Package.swift` embeds `SPMInfo.plist` as a
/// `__TEXT,__info_plist` section, so the SPM binary has the same identifier as the .app and
/// both launch paths resolve `UserDefaults.standard` to `canonical`. That corrects all seven
/// `@AppStorage`/`UserDefaults.standard` call sites at once, upstream of every one of them,
/// with none to miss — where threading a named suite through the call sites would have been
/// seven chances to split state *within* a build, which is worse than a clean split between
/// two. What is left here is the names, and moving the old domain's contents across.
///
/// **#86 took the other half of that trade after all, and on purpose.** One domain for both
/// launch paths also meant a helm built from a worktree writes the operator's live
/// `helmWorkspaceContexts`, so the seven call sites now go through `store` and
/// `HELM_DEFAULTS_SUITE` can move all seven at once. The argument above still holds: what it
/// warns against is threading a suite through the call sites *by hand*, and the guard test in
/// `DefaultsDomainTests` is what keeps it from becoming that — `UserDefaults.standard` and a
/// storeless `@AppStorage` anywhere outside this file both fail the suite.
///
/// **`swift test`, not `swift build`.** The gate runs them as separate steps and a violation
/// compiles perfectly well, so it is caught by the run and not by the compiler.
enum DefaultsDomain {
    /// The domain both launch paths now resolve to.
    ///
    /// Stated in three places that must agree: here (via `HelmWire.DefaultsSuite`),
    /// `CFBundleIdentifier` in `SPMInfo.plist`, and `PRODUCT_BUNDLE_IDENTIFIER` in
    /// `project.yml`. `DefaultsDomainTests` fails on drift, because drift here silently
    /// restores the two-domain bug.
    static let canonical = DefaultsSuite.canonical

    /// What `swift run helm` used to get: no identifier, so the process name.
    static let legacy = DefaultsSuite.legacy

    // MARK: - The opt-in override

    /// Set this to move every default helm owns into a suite of its own.
    ///
    /// **Unset is today's behaviour, exactly** — `canonical`, both launch paths, one answer to
    /// *"did it persist?"*. That is #45's win and nothing here touches it.
    ///
    /// Set is for the second instance: a helm built from a worktree can be launched, filled,
    /// quit, relaunched and hand-corrupted with no reachable path to the operator's state.
    /// That was the missing affordance in #86 — it cost Task 27 of the workbench plan
    /// outright, and made two separate agents hand-roll a throwaway `PRODUCT_BUNDLE_IDENTIFIER`
    /// to verify anything safely (PRs #97, #100). The trick worked; reinventing it did not
    /// scale, and an agent who forgot it would have written over live workspaces.
    ///
    ///     HELM_DEFAULTS_SUITE=helm-task27 swift run helm
    ///     defaults read helm-task27
    static let suiteVariable = DefaultsSuite.suiteVariable

    /// What `HELM_DEFAULTS_SUITE` asked for, as a decision rather than a string.
    ///
    /// **The decision itself lives in `HelmWire.DefaultsSuite` (#221), not here.**
    /// `SpoolDirectory.resolve` — reached both by a running helm and by the standalone
    /// `helm-spool`/`helm-close`/`helm-capture` CLIs — has to make this exact call to find the
    /// isolated spool a suite implies, and a CLI outside this process cannot reach a type that
    /// lives in `Helm`. Rather than restating the parsing rules a second time (the
    /// `tools/*.swift` bug this whole library exists to end, one door over), this delegates.
    /// `DefaultsSuite`'s header has the full reasoning for each rule below; nothing about the
    /// decision changed, only where it is made.
    typealias Override = DefaultsSuite.Override

    /// Read `HELM_DEFAULTS_SUITE` and decide. Pure, so every rule is a test — see
    /// `DefaultsDomainTests` and `DefaultsSuite`'s own header.
    static func override(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Override {
        DefaultsSuite.override(in: environment)
    }

    /// The domain this process persists to, and the `UserDefaults` that writes there.
    ///
    /// Resolved once, on first use, because a process cannot change its mind about this
    /// halfway through and a second reading that disagreed would be a split domain again.
    ///
    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` and is nonetheless
    /// documented thread-safe — which is exactly the case that annotation is for. The
    /// alternative, `@MainActor`, would put the store behind the main actor and every
    /// persistence path here is already reached from off it.
    nonisolated(unsafe) private static let resolved = resolve(override())

    /// A decision turned into the store that carries it out.
    ///
    /// Pulled out of the memoized `resolved` above so it is answerable from `swift test`, for
    /// the reason `TerminalNotifier.canDeliver` gives: resolving once per process is right for
    /// the process and leaves the mapping itself unreachable, and this mapping is where a
    /// decision the parser got right could still be carried out wrong.
    static func resolve(_ override: Override) -> (name: String, defaults: UserDefaults) {
        switch override {
        case .none:
            return (canonical, .standard)
        case .suite(let name):
            // Force-unwrapped deliberately: `override(in:)` has already opened this exact
            // name and found it usable, so a nil here is not an environment problem — it is
            // this file disagreeing with itself, and a silent `.standard` would be the write
            // to live state the whole override exists to prevent.
            return (name, UserDefaults(suiteName: name)!)
        case .refused(let why):
            // The one place helm gives up rather than carrying on. An agent who set the
            // variable is about to do something destructive under the belief that it is
            // contained; being told no, loudly, is the cheap outcome.
            fatalError("\(why)")
        }
    }

    /// The one `UserDefaults` every default helm owns goes through.
    ///
    /// `UserDefaults.standard` survives in this file only, where the migration needs a handle
    /// to reach *other* domains by name. `DefaultsDomainTests` fails if it reappears anywhere
    /// else in `Sources/`, which is what stops a new call site from quietly escaping a suite.
    static var store: UserDefaults { resolved.defaults }

    /// The domain `defaults read` should be pointed at for this process.
    static var activeDomain: String { resolved.name }

    /// Whether this instance is deliberately not the operator's.
    static var isIsolated: Bool { isIsolated(domain: activeDomain) }

    /// The same question about a named domain, and pure so the **polarity** is pinned by a
    /// test rather than by reading it. Backwards, this hides the badge on a test instance and
    /// shows it on the operator's — the two ways of being wrong that matter.
    static func isIsolated(domain: String) -> Bool { domain != canonical }

    /// The window's title, which is also what `winshot --list` and `helm-spawn` see.
    ///
    /// Two helms are the *normal* state while building helm, and `AGENTS.md` records that
    /// they are indistinguishable by name — so an isolated one says so in the one place an
    /// agent outside the process can read. That makes this a safety mechanism another tool
    /// depends on, not decoration, which is why it is pinned rather than eyeballed.
    static var windowTitle: String { windowTitle(for: activeDomain) }

    static func windowTitle(for domain: String) -> String {
        isIsolated(domain: domain) ? "helm — \(domain)" : "helm"
    }

    /// Written into `canonical` once the move has run, so it runs exactly once. Its value is
    /// the domain that was drained — the question anyone reading it will actually have.
    static let migratedFromKey = "helmDefaultsMigratedFrom"

    /// Left in `legacy` in place of its contents. A drained domain that says where its state
    /// went is the difference between `defaults read helm` answering the question and
    /// answering a different one convincingly, which is the failure #45 is about.
    static let movedToKey = "helmDefaultsMovedTo"

    /// What `HelmApp.init` calls: the move, unless this process is an isolated instance.
    ///
    /// **A suite must never inherit the legacy domain.** The move is destructive on the far
    /// side — it empties `helm` and leaves a forwarding note — and it happens once per
    /// machine. A test instance that ran it would swallow state the operator's own build has
    /// not migrated yet, and the marker it left behind would stop that build from ever
    /// trying. So the rule lives here, where it is a unit test, rather than as a condition at
    /// a call site inside `HelmApp.init` that nothing can reach.
    ///
    /// - Returns: whether anything moved.
    @discardableResult
    static func migrateLegacyDomainAtLaunch(
        override resolvedOverride: Override = override(),
        from legacyDomain: String = legacy,
        to canonicalDomain: String = canonical,
        using defaults: UserDefaults = .standard
    ) -> Bool {
        guard resolvedOverride == .none else { return false }
        return migrateLegacyDomain(
            from: legacyDomain, to: canonicalDomain, using: defaults)
    }

    /// Move the old process-name domain's contents into the canonical one, once.
    ///
    /// Wholesale rather than by key list, and the old domain wins every collision. Both are
    /// deliberate:
    ///
    /// - **Wholesale**, because the keys span five feature slices plus the window frames and
    ///   split positions AppKit writes on its own, and a hand-kept list is a thing to get
    ///   wrong. Copying the domain cannot miss one.
    /// - **Old wins**, because the old domain is the one `swift run helm` has been writing:
    ///   it holds the terminals that are live and the store ⌘O opens on, where the canonical
    ///   domain holds whatever the last `make app` happened to leave. Keys only the canonical
    ///   domain has — it is older, and accumulated some the other never got — survive the
    ///   merge untouched, so the merge is strictly additive on that side.
    ///
    /// **Except for the collection keys**, which are unioned instead — see
    /// `mergedCollections`. That distinction is #60, and it cost two workspaces.
    ///
    /// Safe on every launch: after the first, this is one plist read.
    ///
    /// - Returns: whether anything moved.
    @discardableResult
    static func migrateLegacyDomain(
        from legacyDomain: String = legacy,
        to canonicalDomain: String = canonical,
        using defaults: UserDefaults = .standard
    ) -> Bool {
        guard legacyDomain != canonicalDomain else { return false }

        var destination = defaults.persistentDomain(forName: canonicalDomain) ?? [:]
        guard destination[migratedFromKey] == nil else { return false }

        // The forwarding note is not state, so it never travels — otherwise a domain that
        // has already been drained would look like it still had something to give.
        let source = (defaults.persistentDomain(forName: legacyDomain) ?? [:])
            .filter { $0.key != movedToKey }
        guard !source.isEmpty else { return false }

        // Computed before the wholesale copy, because the copy overwrites the very values it
        // has to read. Applied after it, because it is a correction to that copy's result.
        let collections = mergedCollections(legacy: source, canonical: destination)
        destination.merge(source) { _, fromLegacy in fromLegacy }
        destination.merge(collections) { _, merged in merged }
        destination[migratedFromKey] = legacyDomain
        defaults.setPersistentDomain(destination, forName: canonicalDomain)

        // The copy has to be on disk before the original is dropped. `synchronize()` is
        // deprecated and used deliberately: cfprefsd writes on its own schedule, and emptying
        // the old domain is the one step here that cannot be repeated.
        defaults.synchronize()

        // And then read it back rather than assume it. This runs once per machine, against
        // state that was never rehearsed on, and `setPersistentDomain` reports nothing — so a
        // write that did not land would otherwise be followed by deleting the only other copy.
        // Giving up here costs a retry next launch; not checking costs the state.
        guard defaults.persistentDomain(forName: canonicalDomain)?[migratedFromKey] != nil else {
            return false
        }

        // `setPersistentDomain` replaces a domain rather than merging into it, so this drops
        // what was copied and leaves the forwarding note in a single write.
        defaults.setPersistentDomain([movedToKey: canonicalDomain], forName: legacyDomain)
        return true
    }

    /// The keys whose value is a *collection*, merged member by member instead of replaced.
    ///
    /// **This is the whole of #60.** Last-writer-wins is right for a scalar and wrong for a
    /// collection, and the difference is not a detail of these two keys — it is what kind of
    /// value they hold. A dock width has one correct answer and the live domain has it. A
    /// workspace list does not: the two domains hold different *subsets of the same
    /// collection* — the legacy one accumulated whatever was opened under `swift run`, the
    /// canonical one is older and larger — so neither is authoritative and overwriting either
    /// deletes the members only the loser had. It deleted two workspaces from the operator's
    /// bar on the first launch after #45 merged.
    ///
    /// The keys are asked of the slices that own them rather than spelled out again here, so
    /// renaming one cannot silently un-fix this.
    ///
    /// - Returns: only the keys it could merge. Anything absent keeps whatever the wholesale
    ///   copy gave it.
    private static func mergedCollections(
        legacy: [String: Any], canonical: [String: Any]
    ) -> [String: Any] {
        var merged: [String: Any] = [:]
        if let workspaces = unionedWorkspaces(
            legacy: legacy[WorkspacePersistence.listKey],
            canonical: canonical[WorkspacePersistence.listKey])
        {
            merged[WorkspacePersistence.listKey] = workspaces
        }
        if let contexts = mergedContexts(
            legacy: legacy[WorkspaceContextStore.key],
            canonical: canonical[WorkspaceContextStore.key])
        {
            merged[WorkspaceContextStore.key] = contexts
        }
        return merged
    }

    /// Every folder either domain had open, in the order the legacy one had them, with what
    /// only the canonical one knew appended.
    ///
    /// Legacy first because that is the bar the operator was last looking at: its ⌃1…⌃n keep
    /// landing on the same workspaces, and the forgotten folders arrive after them rather than
    /// reshuffling the row. De-duplication is on `Workspace`, whose decoder runs
    /// `Workspace.normalized`, so `/a/` and `/a` are one folder here exactly as they are
    /// everywhere else.
    private static func unionedWorkspaces(legacy: Any?, canonical: Any?) -> String? {
        // A blob that does not decode has no members to preserve — `WorkspacePersistence.load`
        // reads it as an empty list too — so the side that does decode stands in whole. That
        // is the same rule as the union, not an exception to it: a corrupt legacy list must
        // not be copied over a readable canonical one on the one launch that can do it.
        guard let fromLegacy = decodedWorkspaces(legacy) else { return canonical as? String }
        guard let fromCanonical = decodedWorkspaces(canonical) else { return nil }

        var seen: Set<Workspace> = []
        let union = (fromLegacy + fromCanonical).filter { seen.insert($0).inserted }
        guard let data = try? JSONEncoder().encode(union) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodedWorkspaces(_ raw: Any?) -> [Workspace]? {
        guard let json = raw as? String else { return nil }
        return try? JSONDecoder().decode([Workspace].self, from: Data(json.utf8))
    }

    /// The per-workspace contexts, merged path by path.
    ///
    /// The same argument as the list one shape down, and with more to lose: a dropped member
    /// here is a whole workspace's tab row, not a folder that can be reopened with one ⌘⇧O.
    /// Where both domains hold a context for one path the legacy one wins, on the same "it was
    /// the live domain" grounds the scalars use.
    private static func mergedContexts(legacy: Any?, canonical: Any?) -> String? {
        guard let fromLegacy = decodedContexts(legacy) else { return canonical as? String }
        guard let fromCanonical = decodedContexts(canonical) else { return nil }

        let merged = fromCanonical.merging(fromLegacy) { _, fromLegacy in fromLegacy }
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Contexts travel as **opaque JSON**, never decoded into `WorkspaceContext`.
    ///
    /// `WorkspaceContextStore.load` fails atomically across the whole dictionary, deliberately
    /// — one entry the app can no longer act on discards them all. Decoding here would apply
    /// that rule during the *move*, where the only job is not to lose bytes, and one stale
    /// entry would take every other workspace's context with it. The app still gets to apply
    /// its own rule afterwards, on its own terms.
    ///
    /// Keys are normalised on the way in so the prefer-legacy rule above compares the two
    /// paths the way helm does. Nothing helm writes can collide under it — contexts are keyed
    /// by `Workspace.path`, which is already normalised — so the tiebreak only ever picks
    /// between two spellings of one folder.
    private static func decodedContexts(_ raw: Any?) -> [String: Any]? {
        guard let json = raw as? String,
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let contexts = object as? [String: Any]
        else { return nil }
        return Dictionary(
            contexts.map { (Workspace.normalized($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first })
    }
}

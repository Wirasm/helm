import Foundation

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
enum DefaultsDomain {
    /// The domain both launch paths now resolve to.
    ///
    /// Stated in three places that must agree: here, `CFBundleIdentifier` in `SPMInfo.plist`,
    /// and `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`. `DefaultsDomainTests` fails on drift,
    /// because drift here silently restores the two-domain bug.
    static let canonical = "com.wirasm.helm"

    /// What `swift run helm` used to get: no identifier, so the process name.
    static let legacy = "helm"

    /// Written into `canonical` once the move has run, so it runs exactly once. Its value is
    /// the domain that was drained — the question anyone reading it will actually have.
    static let migratedFromKey = "helmDefaultsMigratedFrom"

    /// Left in `legacy` in place of its contents. A drained domain that says where its state
    /// went is the difference between `defaults read helm` answering the question and
    /// answering a different one convincingly, which is the failure #45 is about.
    static let movedToKey = "helmDefaultsMovedTo"

    /// Move the old process-name domain's contents into the canonical one, once.
    ///
    /// Wholesale rather than by key list, and the old domain wins every collision. Both are
    /// deliberate:
    ///
    /// - **Wholesale**, because the keys span five feature slices plus the window frames and
    ///   split positions AppKit writes on its own, and a hand-kept list is a thing to get
    ///   wrong. Copying the domain cannot miss one.
    /// - **Old wins**, because the old domain is the one `swift run helm` has been writing:
    ///   it holds the workspaces that are open and the terminals that are live, where the
    ///   canonical domain holds whatever the last `make app` happened to leave. Keys only the
    ///   canonical domain has — it is older, and accumulated some the other never got —
    ///   survive the merge untouched, so the merge is strictly additive on that side.
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

        destination.merge(source) { _, fromLegacy in fromLegacy }
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
}

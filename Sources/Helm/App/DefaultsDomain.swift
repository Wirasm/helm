import Foundation
import HelmWire

/// The one `UserDefaults` domain helm persists to.
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
/// two. What is left here is the names. The one-time move of the old domain's contents ran
/// once per machine and was deleted in #377.
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
    /// `UserDefaults.standard` survives in this file only, as what `.none` resolves to.
    /// `DefaultsDomainTests` fails if it reappears anywhere else in `Sources/`, which is what
    /// stops a new call site from quietly escaping a suite.
    static var store: UserDefaults { resolved.defaults }

    /// The domain `defaults read` should be pointed at for this process.
    static var activeDomain: String { resolved.name }

    /// Whether this instance is deliberately not the operator's.
    static var isIsolated: Bool { isIsolated(domain: activeDomain) }

    /// The same question about a named domain, and pure so the **polarity** is pinned by a
    /// test rather than by reading it. Backwards, this hides the badge on a test instance and
    /// shows it on the operator's — the two ways of being wrong that matter.
    static func isIsolated(domain: String) -> Bool { domain != canonical }

    /// The window's title, which is also what `winshot --list` sees.
    ///
    /// Two helms are the *normal* state while building helm, and `AGENTS.md` records that
    /// they are indistinguishable by name — so an isolated one says so in the one place an
    /// agent outside the process can read. That makes this a safety mechanism another tool
    /// depends on, not decoration, which is why it is pinned rather than eyeballed.
    static var windowTitle: String { windowTitle(for: activeDomain) }

    static func windowTitle(for domain: String) -> String {
        isIsolated(domain: domain) ? "helm — \(domain)" : "helm"
    }
}

import Foundation

/// The decision `HELM_DEFAULTS_SUITE` asks for, extracted from `DefaultsDomain`
/// (`Sources/Helm/App/DefaultsDomain.swift`) so `SpoolDirectory.resolve` can make the identical
/// call a running helm makes, from inside `HelmWire` where `DefaultsDomain` itself cannot be
/// reached. The standalone spool scripts cannot call this either — they cannot `import HelmWire`
/// at all (`AGENTS.md`'s "Why the spool is a script, and must stay one"), and **which scripts
/// those are is `AGENTS.md`'s list, deliberately not restated here**: this comment named three of
/// them for as long as there were three, and stayed at three through `helm-command`, `helm-select`
/// and `helm-name` — so each carries its own hand-written copy of
/// just the boolean this decision reduces to for their purposes: is a suite name set, and is it
/// not `canonical`. That is a narrower duplicate than `Override` (no refusal reasons, no
/// `NSGlobalDomain`/path/legacy checks), on the same honest-duplicate footing as the rest of the
/// spool's wire format in `tools/`.
///
/// **Why this one piece of `DefaultsDomain` and not the rest.** `SpoolDirectory` needs to know
/// exactly one thing to find the right spool: is this process isolated, and under what name —
/// `AGENTS.md` calls it "the suite moves the spool too, automatically, rather than by
/// remembering". Everything else `DefaultsDomain` does — draining the legacy domain, merging
/// collections, resolving an actual `UserDefaults` — is `@MainActor`-adjacent app lifecycle with
/// no reason to exist outside the process, and stays there. This is the one part that is
/// already pure: a function of an environment dictionary, with no live state to read. Moving
/// only that out is what keeps `HelmWire` a library of values rather than a second `DefaultsDomain`.
///
/// `DefaultsDomain.canonical`, `.legacy`, `.suiteVariable`, `.Override` and `.override(in:)` now
/// delegate here; nothing about its public shape changed, so every existing call site and every
/// `DefaultsDomainTests` assertion still holds.
package enum DefaultsSuite {
    /// The domain both `Helm.app` and `swift run helm` resolve to. Stated here because
    /// `SpoolDirectory` needs it to recognise "no override", and `DefaultsDomain.canonical`
    /// delegates to this rather than restating the literal a second time.
    package static let canonical = "com.wirasm.helm"

    /// What `swift run helm` got before #45: no bundle identifier, so the process name.
    package static let legacy = "helm"

    /// Set this to move every default helm owns — and, via `SpoolDirectory`, its spool — into a
    /// suite of its own. See `DefaultsDomain.suiteVariable` for the full argument; this is the
    /// same variable, read the same way.
    package static let suiteVariable = "HELM_DEFAULTS_SUITE"

    /// What `HELM_DEFAULTS_SUITE` asked for, as a decision rather than a string.
    package enum Override: Equatable {
        /// Unset, blank, or naming `canonical` — today's behaviour, exactly.
        case none
        /// An isolated suite, by name.
        case suite(String)
        /// Set to something helm will not honour. The string says why.
        ///
        /// **`SpoolDirectory` treats this the same as `.none`, deliberately.** The app itself
        /// refuses to launch on a `.refused` override (`DefaultsDomain.resolve`'s `fatalError`),
        /// so by the time a *running* helm ever asks `SpoolDirectory.resolve` the override was
        /// already `.none` or a valid `.suite`. A standalone CLI has no such gate — it can be
        /// run with `HELM_DEFAULTS_SUITE=NSGlobalDomain` against a helm that never started — and
        /// falling back to the shared spool rather than crashing is what lets it report "no
        /// spool there" instead of a decoder failure with no explanation.
        case refused(String)
    }

    /// Read `HELM_DEFAULTS_SUITE` and decide. Pure, so every rule is a test — see
    /// `DefaultsDomainTests` for the case-by-case reasoning this mirrors.
    package static func override(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Override {
        guard let raw = environment[suiteVariable] else { return .none }
        guard !raw.isEmpty else { return .none }

        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .refused(
                "\(suiteVariable) is set but names no domain — it is whitespace. Unset it to "
                    + "mean the default; a blank value is a bug in whatever built it.")
        }

        guard name != canonical else { return .none }

        guard name != legacy else {
            return .refused(
                "\(suiteVariable)=\(name) names the domain the legacy migration drains, "
                    + "so anything written there is liable to be emptied. Pick another name.")
        }
        guard !name.contains("/") else {
            return .refused("\(suiteVariable)=\(name) looks like a path; a suite name is a domain.")
        }
        guard UserDefaults(suiteName: name) != nil else {
            return .refused("\(suiteVariable)=\(name) is not a usable UserDefaults suite name.")
        }
        return .suite(name)
    }
}

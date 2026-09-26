import Foundation

/// The decision `HELM_DEFAULTS_SUITE` asks for, extracted from `DefaultsDomain`
/// (`Sources/Helm/App/DefaultsDomain.swift`) so `BenchRoot` can make the identical call from inside
/// `HelmWire`, where `DefaultsDomain` itself cannot be reached: "is this helm isolated, and under
/// what name?" has one answer for the defaults and for benchd's root. It is the one part of
/// `DefaultsDomain` that is already pure — a function of an environment dictionary — and the
/// rest stays app lifecycle. `DefaultsDomain.canonical`, `.suiteVariable`, `.Override` and
/// `.override(in:)` delegate here.
package enum DefaultsSuite {
    /// The domain both `Helm.app` and `swift run helm` resolve to. `DefaultsDomain.canonical`
    /// delegates to this rather than restating the literal a second time.
    package static let canonical = "com.wirasm.helm"

    /// What `swift run helm` got before #45: no bundle identifier, so the process name. The
    /// domain still exists on machines that ran a build from then, holding either old state or
    /// the forwarding note the one-time move left (deleted in #377), so it is never a suite.
    /// The mail hooks, the pi extension and both mail skills refuse it by the same rule (#285).
    package static let legacy = "helm"

    /// Set this to move every default helm owns — and, via `BenchRoot`, benchd's root — into a
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
        /// The app refuses to launch on it (`DefaultsDomain.resolve`), and `BenchRoot` refuses
        /// to resolve a root under it.
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
                "\(suiteVariable)=\(name) names the domain `swift run helm` wrote before #45, "
                    + "which is not an isolated suite. Pick another name.")
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

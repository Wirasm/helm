import Foundation
import XCTest

/// The package name `Package.swift` and `project.yml` must agree on for Swift's `package`-level
/// access (SE-0386) — the access level `HelmWire`'s spool types use, #221 — to resolve
/// identically under `swift build` and under `make app`.
///
/// **Why this is its own drift guard.** SPM derives the compiler's `-package-name` flag from
/// `Package.swift`'s own `name: "helm"` automatically, so `swift build` and `swift test` stay
/// green no matter what `project.yml` says. `xcodegen generate` stays green too — it only
/// regenerates the Xcode project, it does not build it. A hand-authored xcodegen project has no
/// such wiring, so `HelmWire` and `Helm` each need `SWIFT_PACKAGE_NAME` spelled out by hand in
/// `project.yml`, held together only by two comments cross-referencing each other — the same
/// hand-maintained-set shape #221 exists to remove, one level down in the build config. Nothing
/// in the whole Swift gate would notice a drift: it only surfaces at `make app`, as "the package
/// access level used on 'X' requires a package name", a message that names no file to fix. This
/// is `DefaultsDomainTests.testEveryBuildPathNamesTheOneDomain` one level down — in the build
/// config that makes `package` access resolve, rather than in the bundle identity it protects.
final class SwiftPackageNameTests: XCTestCase {
    /// The drift guard. If `Package.swift`'s name and either target's `SWIFT_PACKAGE_NAME`
    /// disagree, `HelmWire`'s `package` declarations stop being visible from that target under
    /// `make app` while every other gate stage stays green — the exact silent failure #221's PR
    /// review found by hand.
    func testPackageSwiftAndProjectYmlAgreeOnThePackageName() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let packageName = try XCTUnwrap(
            firstCapture(of: #"let package = Package\(\s*name:\s*"([^"]+)""#, in: manifest),
            "Package.swift must declare `let package = Package(name: \"...\", …)` — nothing "
                + "here found the package's own name, so there is nothing to compare project.yml "
                + "against")

        let spec = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"), encoding: .utf8)

        // Both targets that compile against HelmWire's `package`-level API. A target added to
        // that list without a matching entry here would pass silently — the same asymmetry
        // `DefaultsDomainTests` calls out for the resources build phase, one door over.
        for target in ["HelmWire", "Helm"] {
            let block = try XCTUnwrap(
                targetBlock(named: target, in: spec),
                "project.yml must declare a `\(target):` target under `targets:`")
            let declared = try XCTUnwrap(
                firstCapture(of: #"SWIFT_PACKAGE_NAME:\s*(\S+)"#, in: block),
                "\(target) in project.yml must set SWIFT_PACKAGE_NAME — without it Xcode has no "
                    + "`-package-name`, and `package`-level access in HelmWire resolves under "
                    + "`swift build` (SPM sets this itself from Package.swift) and fails only at "
                    + "`make app`, with \"the package access level used on 'X' requires a "
                    + "package name\" naming no file to fix")
            XCTAssertEqual(
                declared, packageName,
                "\(target)'s SWIFT_PACKAGE_NAME (\"\(declared)\") in project.yml must match "
                    + "Package.swift's `name: \"\(packageName)\"` — bring them back in step, or "
                    + "HelmWire's `package`-level types stop resolving from \(target) under "
                    + "`make app` while `swift build` and `xcodegen generate` both stay green")
        }
    }

    /// One top-level target's block in `project.yml` — from its own `  <name>:` line up to the
    /// next line at the same indentation or shallower.
    ///
    /// Not a YAML parser, a slice — the same register `testEveryBuildPathNamesTheOneDomain` reads
    /// `project.yml` in. Enough to answer "does this target's own settings set X", which is all
    /// this asks; a search across the whole file could not tell `HelmWire`'s setting from
    /// `Helm`'s, or notice one target missing it entirely.
    private func targetBlock(named name: String, in spec: String) -> String? {
        let lines = spec.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0 == "  \(name):" }) else { return nil }
        let end =
            lines[(start + 1)...].firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("    ") })
            ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    private func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
            let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captured])
    }

    /// Four levels up from `Tests/HelmTests/App/`, the same walk `DefaultsDomainTests` does —
    /// both read build files no compiler touches, from a unit test that has to find them itself.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}

// swift-tools-version: 6.0
import PackageDescription

// SwiftLint, pinned by version and checksum, for the size and complexity limits in
// `.swiftlint.yml` (#418). It is its own package rather than a dependency of helm's
// manifest so linting never resolves helm's graph, which needs the gitignored
// `vendor/libghostty-spm`. The same reason keeps the spool tools out of SPM (AGENTS.md).
//
// Run it through `scripts/check-size.sh`, never directly: that script passes
// `--disable-keychain` (without it SwiftPM can stall for minutes on a keychain lookup)
// and prints the declaration under each finding.
//
// A version bump goes in its own PR: SwiftLint's counting can change between releases,
// and every legacy marker records a value measured with this one.
let package = Package(
    name: "HelmLint",
    targets: [
        .binaryTarget(
            name: "SwiftLintBinary",
            url:
                "https://github.com/realm/SwiftLint/releases/download/0.65.1/SwiftLintBinary.artifactbundle.zip",
            checksum: "c3a1d77647ca18c1b7e9be7dbc6cd4490d26422f28814b76370244ff61970869"
        ),
        .plugin(
            name: "Lint",
            capability: .command(
                intent: .custom(verb: "lint", description: "Run the pinned SwiftLint")
            ),
            dependencies: ["SwiftLintBinary"]
        ),
    ]
)

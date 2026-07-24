// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "helm",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned EXACT on purpose: libghostty's embedding API is pre-1.0 and
        // changes between releases. Bump deliberately, re-reading the wrapper's
        // sources at the new tag — see docs/SPIKE.md.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.3.1"),
    ],
    targets: [
        // The spike runs as a plain SPM executable (`swift run helm`) for fast iteration.
        // Graduation to a real .app bundle (XcodeGen + entitlements) happens after the
        // libghostty embed is proven — see docs/SPIKE.md.
        .executableTarget(
            name: "Helm",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/Helm"
        ),
        // Non-GUI smoke: ghostty_init + config load + app create, no window.
        .testTarget(
            name: "HelmTests",
            dependencies: ["Helm"],
            path: "Tests/HelmTests"
        ),
    ]
)

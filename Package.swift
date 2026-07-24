// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "helm",
    platforms: [.macOS(.v14)],
    targets: [
        // The spike runs as a plain SPM executable (`swift run helm`) for fast iteration.
        // Graduation to a real .app bundle (XcodeGen + entitlements) happens after the
        // libghostty embed is proven — see docs/SPIKE.md.
        .executableTarget(name: "Helm", path: "Sources/Helm")
    ]
)

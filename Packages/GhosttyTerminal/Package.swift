// swift-tools-version: 6.0
import PackageDescription

// helm's Ghostty embedding: official Ghostty, built by us, plus the macOS slice of the
// Swift wrapper helm uses. docs/VENDORED.md ("Ghostty") says where each half came from and
// `scripts/bump-ghostty.sh` is how both move.
//
// GhosttyKit is Ghostty's own `zig build -Demit-xcframework` output at the commit named
// below, unpatched, hosted as a release asset on Wirasm/helm and pinned by checksum.
// The release tag is derived from the commit, so the pin is these two lines, and the script
// rewrites both.
let ghosttyCommit = "6301810a48aaa3426887a4316668f18833a40138"
let ghosttyKitChecksum = "70b84d951dd31fdfaaf1229c6178764003136967025485b6f627959b9c87d635"
let ghosttyKitURL =
    "https://github.com/Wirasm/helm/releases/download/ghostty-\(ghosttyCommit.prefix(12))/GhosttyKit.xcframework.zip"

let package = Package(
    name: "GhosttyTerminal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", exact: "2.2.0"),
    ],
    targets: [
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            // What the static libghostty references and nothing autolinks. SwiftPM got
            // GameController for free and xcodebuild did not (`GCController` undefined,
            // from Dear ImGui's macOS backend in the inspector).
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("GameController"),
                .linkedFramework("Metal"),
            ]
        ),
        .binaryTarget(name: "GhosttyKit", url: ghosttyKitURL, checksum: ghosttyKitChecksum),
    ]
)

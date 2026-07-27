// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "helm",
    platforms: [.macOS(.v14)],
    products: [
        // Explicit lowercase product so `swift run helm` works (the target is `Helm`,
        // and SPM would otherwise auto-name the product after it, case-sensitively).
        .executable(name: "helm", targets: ["Helm"])
    ],
    dependencies: [
        // Pinned EXACT on purpose: libghostty's embedding API is pre-1.0 and
        // changes between releases. Bump deliberately, re-reading the wrapper's
        // sources at the new tag — see docs/SPIKE.md.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.3.1"),
        // Hot reload for UI work — see docs/VENDORED.md. Both are DEBUG-only in
        // effect: InjectionNext compiles to nothing in release, Inject's
        // modifiers become no-ops. Kept permanently configured (upstream's own
        // advice) so iterating never needs a manifest edit.
        //
        // Why this matters more for helm than for a normal app: a relaunch
        // kills every pty, so a UI tweak costs whatever agent was running in
        // the terminal. Injection patches the LIVE process — only helm's own
        // recompiled Swift is swapped, libghostty's binary framework and the
        // shells under it are never touched.
        .package(url: "https://github.com/johnno1962/InjectionNext.git", exact: "2.0.1"),
        .package(url: "https://github.com/krzysztofzablocki/Inject.git", exact: "1.6.0"),
    ],
    targets: [
        // The spike runs as a plain SPM executable (`swift run helm`) for fast iteration.
        // Graduation to a real .app bundle (XcodeGen + entitlements) happens after the
        // libghostty embed is proven — see docs/SPIKE.md.
        .executableTarget(
            name: "Helm",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "InjectionNext", package: "InjectionNext"),
                .product(name: "Inject", package: "Inject"),
            ],
            path: "Sources/Helm",
            resources: [
                // Vendored renderers, pinned — version + source URL + sha256
                // in docs/VENDORED.md. The artifact pane is offline by rule:
                // markdown converts and diagrams render from these files,
                // never from a CDN. Keep in lockstep with project.yml's
                // resources phase.
                .copy("Resources/mermaid.min.js"),
                .copy("Resources/marked.min.js"),
                // Ghostty shell-integration script tree (bash/zsh/fish/…),
                // vendored at the embed's exact source commit — provenance in
                // docs/VENDORED.md. Copied as a directory so the hierarchy
                // (and zsh's hidden .zshenv) survives; GhosttyResources points
                // GHOSTTY_RESOURCES_DIR at the bundled `ghostty/` dir.
                .copy("Resources/ghostty"),
            ],
            // What makes Swift methods swappable at runtime: the linker emits
            // indirect stubs injection can repoint. Debug only — release keeps
            // direct calls. Mirrored in project.yml's Debug OTHER_LDFLAGS.
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-interposable"],
                    .when(platforms: [.macOS], configuration: .debug)
                )
            ]
        ),
        // Non-GUI smoke: ghostty_init + config load + app create, no window.
        .testTarget(
            name: "HelmTests",
            dependencies: ["Helm"],
            path: "Tests/HelmTests"
        ),
    ]
)

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
        // Ghostty: official Ghostty built by us, plus the Swift wrapper helm uses, as a local
        // package. The pin (a Ghostty commit and the checksum of our build of it) lives in
        // Packages/GhosttyTerminal/Package.swift; docs/VENDORED.md says how it moves.
        .package(path: "Packages/GhosttyTerminal"),
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
        // The operator's keymap file (`rules/keymap.toml`, #356). Pure Swift, Codable, no
        // system dependency, so the Swift gate still needs only the toolchain. Pinned EXACT;
        // mirrored in project.yml.
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    ],
    targets: [
        // The values helm shares with its own tests and pins against benchd's fixtures — the bench
        // document, the verbs, mail, the suite and root rules. No AppKit, no `@MainActor`,
        // nothing app-shaped.
        .target(
            name: "HelmWire",
            path: "Sources/HelmWire"
        ),
        // The spike runs as a plain SPM executable (`swift run helm`) for fast iteration.
        // Graduation to a real .app bundle (XcodeGen + entitlements) happens after the
        // libghostty embed is proven — see docs/SPIKE.md.
        .executableTarget(
            name: "Helm",
            dependencies: [
                "HelmWire",
                .product(name: "GhosttyTerminal", package: "GhosttyTerminal"),
                .product(name: "InjectionNext", package: "InjectionNext"),
                .product(name: "Inject", package: "Inject"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
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
                // helm's OWN script, not a vendored one: the canvas annotation
                // bridge (#197). It lived in a Swift string literal, where the
                // only test available was a substring check and three PRs in a
                // row shipped a defect every such check passed. Same loader,
                // same lockstep with project.yml.
                .copy("Resources/canvas-annotation.js"),
                // Ghostty shell-integration script tree (bash/zsh/fish/…),
                // vendored at the embed's exact source commit — provenance in
                // docs/VENDORED.md. Copied as a directory so the hierarchy
                // (and zsh's hidden .zshenv) survives; GhosttyResources points
                // GHOSTTY_RESOURCES_DIR at the bundled `ghostty/` dir.
                .copy("Resources/ghostty"),
            ],
            linkerSettings: [
                // What makes Swift methods swappable at runtime: the linker emits
                // indirect stubs injection can repoint. Debug only — release keeps
                // direct calls. Mirrored in project.yml's Debug OTHER_LDFLAGS.
                .unsafeFlags(
                    ["-Xlinker", "-interposable"],
                    .when(platforms: [.macOS], configuration: .debug)
                ),
                // Give the bare SPM executable a bundle identifier. A non-bundled Mach-O
                // has no Info.plist to read one from, so `UserDefaults.standard` fell back
                // to the process name and `swift run helm` persisted to a `helm` domain
                // while Helm.app persisted to `com.wirasm.helm` — issue #45. Embedding the
                // plist as a __TEXT,__info_plist section is what CFBundle reads for a
                // main bundle that is not a bundle, and it fixes every `@AppStorage` and
                // `UserDefaults.standard` call site at once, upstream of all of them.
                //
                // NOT debug-only, unlike the flag above: which domain state lands in is
                // not a debugging affordance. `Context.packageDirectory` because the
                // linker resolves this path against its own working directory, which is
                // wherever `swift build` was invoked from, not the package root.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/SPMInfo.plist",
                ])
            ]
        ),
        // Non-GUI smoke: ghostty_init + config load + app create, no window.
        .testTarget(
            name: "HelmTests",
            dependencies: ["Helm", "HelmWire"],
            path: "Tests/HelmTests",
            resources: [
                // Real `archon --json` output, captured rather than typed. This PR shipped a
                // decoder built from an imagined payload shape, with fixtures written from the
                // same imagination — 514 tests green while the feature could not display a
                // single run. A literal in a test file can drift with the decoder; a captured
                // file cannot, because nobody edits it to make a test pass.
                //
                // Not mirrored in project.yml: its Helm target has `testTargets: []`, so the
                // .app build never sees Tests/ at all.
                .copy("Archon/Fixtures"),
                // The DOM stub `CanvasScriptRuntime` runs the shipped annotation script
                // against. A file rather than a Swift string literal for exactly the reason
                // the script itself became one (#197) — a harness written as a literal is the
                // same medium, one level up. Named, not a `Fixtures/` directory: `.copy`
                // flattens to the last path component, so a second `Fixtures` would collide
                // with Archon's in the bundle.
                .copy("Canvas/canvas-dom-stub.js")
            ]
        ),
        // The wrapper's own tests: the behaviour helm used to carry as patches (the wakeup
        // fan-out, the clipboard a write lands on). Here rather than in
        // Packages/GhosttyTerminal so the gate's one `swift test` runs them.
        .testTarget(
            name: "GhosttyTerminalTests",
            dependencies: [.product(name: "GhosttyTerminal", package: "GhosttyTerminal")],
            path: "Tests/GhosttyTerminalTests"
        ),
    ]
)

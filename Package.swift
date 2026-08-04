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
        //
        // Currently a LOCAL PATH, not the upstream tag: helm runs ONE
        // TerminalController with N surfaces, and upstream 1.3.1 cannot — its
        // wakeup handlers are single slots that a second surface overwrites
        // and any surface's teardown clears for everyone (TerminalManager's
        // header has the full story). `scripts/patch-libghostty.sh` clones
        // upstream at 1.3.1 into vendor/ (gitignored) and applies
        // Patches/libghostty-spm-multi-surface-wakeup.patch; the pin is still
        // exact, it is just expressed as tag + patch. docs/VENDORED.md records
        // the retirement condition — go back to `exact:` the moment the patch
        // is upstream, or to a fork URL + revision if it is not.
        .package(path: "vendor/libghostty-spm"),
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
            dependencies: ["Helm"],
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
                .copy("Archon/Fixtures")
            ]
        ),
    ]
)

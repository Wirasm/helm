import SwiftUI
import WebKit

// SECURITY: the WKWebViews in this file render LOCAL artifacts only — markdown
// documents converted client-side, and local .html files. No remote content is
// ever loaded: the navigation delegate cancels
// anything that is not this artifact's own helm-canvas:// origin, and the only
// JavaScript that runs is the vendored marked + mermaid (docs/VENDORED.md)
// plus the inline scripts from CanvasHTML — which include the ANNOTATION
// BRIDGE, a script message handler the page can post to.
//
// The bridge is why `CanvasBridgePolicy` exists and why this file is separate
// from URLCanvasViews.swift. A handler on a webview that loads arbitrary
// websites would let any page post into helm, so it is installed here, on local
// artifacts only, and each webview gets its OWN WKUserContentController — the
// controller is a property of the configuration, so one shared instance would
// share every registered script and handler with every webview, which is
// exactly how the bridge would reach the URL source by accident.
//
// "OPENED EXPLICITLY BY THE USER" IS NO LONGER TRUE, and that is deliberate
// (#125). An agent can push an artifact by printing OSC 777, and if the bench has
// no canvas slot yet that push lands in a new column — where the slot's only pane
// is its selection, so the page renders, and an .html artifact runs its JS, with
// no click. A push into an EXISTING canvas slot stays inert until the operator
// selects the tab; only the first one renders unattended.
//
// Weighed rather than inherited: any program writing to the pty can trigger it,
// including a remote ssh session — but it can only name a path that already
// exists on this machine, which the operator could already open with ⌘O, and
// helm's threat model is a single-operator local app with no attacker. The bridge
// is not reachable from that page either: it lives in a named content world
// (below), so the artifact's own JS cannot post to helm. What changed is that a
// click is no longer required, and "appear, don't seize" is about focus and
// selection rather than about rendering.
//
// ADDRESSING (#108): each artifact is served on its own `helm-canvas://<host>`
// origin by `CanvasSchemeHandler`, so a message carries which canvas sent it
// (`CanvasAddress.accepts`). The bridge lives in a NAMED CONTENT WORLD, so the
// page's own JavaScript cannot see `window.webkit.messageHandlers` at all —
// only helm's injected script, which runs in that same world, can post.

// MARK: - When a file canvas has to navigate again

/// Whether a file canvas's webview has to load again — the whole of *"has anything changed?"*
/// for both artifact kinds, as a value rather than a string each view interpolates for itself.
///
/// **`generation` is a stored property here rather than a term someone remembers to include**,
/// and that is the point (#261). It is the only field that can say *"the same path, the same
/// theme, different bytes on disk"* — a **sibling** edit reaches the page through it and through
/// nothing else, because nothing watches a sibling and the artifact's own identity has not
/// moved. It was previously one term in a `"\(…)\u{0}\(…)"` string built twice, and the markdown
/// copy is where dropping it would look like a cleanup: that key already folds in the whole
/// document text, so a counter beside it reads as redundant. It is not — a markdown artifact
/// referencing `./diagram.png` is byte-identical when only the diagram changed. AGENTS.md's rule
/// is exact: prefer a newtype the day the comment gets written.
///
/// `document` is what identifies the bytes on screen, and the two canvases answer it
/// differently: the markdown **source**, because helm generates that page and the same path can
/// render different text; the artifact's **path** for an `.html` one, because the handler reads
/// its bytes per request and the path is all the view knows.
///
/// **Deliberately not shared with `URLCanvasCoordinator`.** That one compares a URL and a
/// generation and has no theme at all — helm does not render a remote page, so there is no third
/// instance of this rule to unify, and pretending there is would mean a field one side must
/// always leave empty.
struct CanvasReloadKey: Equatable {
    let theme: CanvasTheme
    let generation: Int
    let document: String
}

// MARK: - Markdown artifact (one webview per document)

/// A whole markdown artifact as a single WKWebView: CanvasHTML.documentPage
/// carries the source, marked converts it in the page, mermaid renders its
/// fences. Magnification is on — pinch/⌘-scroll zooms the whole document.
/// `generation` bumps on external file change to force a plain reload.
struct MarkdownCanvasView: View {
    /// The artifact this page is, which is what gives it an addressable origin.
    let url: URL
    let markdown: String
    let generation: Int
    /// What the operator is holding, pushed into the page on change.
    let markTool: CanvasMarkTool
    /// Whether a mark is still awaiting a comment. False takes the mark down — the ink, and
    /// since #308 the text highlight with it; the page's `wipe` is one call for both.
    ///
    /// A mark lives as long as the comment field, with one honest exception: an agent
    /// rewriting the artifact reloads the document and takes the mark with it, while the
    /// field stays open. That is deliberate — the ANCHOR is an id or a quote and was decoded
    /// the moment the mark was posted, so the comment is still correct and still worth
    /// writing. Dismissing the field to keep the invariant tidy would throw away what the
    /// operator had already typed, to protect a reminder rather than a record.
    let showsMark: Bool
    /// What the operator selected on the page, for the comment field to anchor to — and
    /// when they clicked away and selected nothing, which is what takes the field down.
    let onSelection: (CanvasPageSelection) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MarkdownCanvasWebView(
            url: url,
            markdown: markdown,
            generation: generation,
            markTool: markTool,
            showsMark: showsMark,
            theme: colorScheme == .dark ? .dark : .light,
            onSelection: onSelection
        )
    }
}

/// How a markdown canvas's webview is built, and when it reloads — `HTMLCanvasPage`'s twin,
/// and here for the same reason (#261): a test cannot construct an `NSViewRepresentableContext`,
/// so a join test would otherwise have to rebuild this rule and would agree with the bug.
///
/// **A markdown canvas serves siblings too, and that is easy to forget.**
/// `CanvasSchemeHandler` resolves a relative request against the artifact's directory with no
/// branch on content type at all, so `![diagram](./diagram.png)` in a `.md` artifact is fetched
/// over exactly the path an `.html` artifact's `<script src>` is. So the sibling-only edit #261
/// describes happens here as well, and the fix — `CanvasModel.refresh()` from a re-push — reaches
/// it through `generation`, the same way.
@MainActor
enum MarkdownCanvasPage {
    /// A webview on the artifact's own `helm-canvas://` origin, with the vendored renderers
    /// injected and the annotation bridge installed. Loads nothing by itself.
    static func makeWebView(
        for path: StandardizedPath, coordinator: CanvasFileCoordinator
    )
        -> WKWebView
    {
        let configuration = WKWebViewConfiguration()
        // Vendored renderers arrive as user scripts at document start; the
        // page's inline script then only converts and renders.
        for script in [CanvasHTML.vendoredMarked(), CanvasHTML.vendoredMermaid()] {
            guard let script else { continue }
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        // The page is generated, not on disk, so the handler serves whatever the
        // coordinator last staged — which is what keeps a theme flip and a file change
        // rendering the current document rather than the one this view was built with.
        configuration.setURLSchemeHandler(
            CanvasSchemeHandler(artifact: URL(fileURLWithPath: path.value)) {
                [weak coordinator] in coordinator?.stagedDocument
            },
            forURLScheme: CanvasAddress.scheme
        )
        coordinator.installBridge(on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsMagnification = true
        return webView
    }

    /// Loads only when the (theme, generation, content) triple actually
    /// changed — file-watch reloads and appearance flips re-render; mere
    /// SwiftUI churn does not.
    ///
    /// **`generation` is not redundant beside `markdown`, and looks it.** The document text is
    /// already in the key, so folding in a counter reads like belt and braces — but a sibling
    /// edit leaves the markdown byte-identical, and then the counter is the only term that can
    /// differ. `CanvasReloadKey` is why that cannot be tidied away.
    static func load(
        _ webView: WKWebView, path: StandardizedPath, markdown: String, generation: Int,
        theme: CanvasTheme, coordinator: CanvasFileCoordinator
    ) {
        let key = CanvasReloadKey(theme: theme, generation: generation, document: markdown)
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key
        coordinator.forgetPushedState()
        coordinator.stagedDocument = Data(
            CanvasHTML.documentPage(markdown: markdown, theme: theme).utf8)
        guard let address = CanvasAddress.url(for: path) else { return }
        webView.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
    }
}

private struct MarkdownCanvasWebView: NSViewRepresentable {
    let url: URL
    let markdown: String
    let generation: Int
    let markTool: CanvasMarkTool
    let showsMark: Bool
    let theme: CanvasTheme
    let onSelection: (CanvasPageSelection) -> Void

    private var path: StandardizedPath { StandardizedPath(url) }

    func makeCoordinator() -> CanvasFileCoordinator {
        CanvasFileCoordinator(host: CanvasAddress.host(for: path), onAnnotation: onSelection)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = MarkdownCanvasPage.makeWebView(for: path, coordinator: context.coordinator)
        load(webView, coordinator: context.coordinator)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: CanvasFileCoordinator) {
        coordinator.removeBridge(from: webView.configuration.userContentController)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
        context.coordinator.pushTool(markTool, theme: theme, to: webView)
        context.coordinator.showMark(showsMark, in: webView)
    }

    private func load(_ webView: WKWebView, coordinator: CanvasFileCoordinator) {
        MarkdownCanvasPage.load(
            webView, path: path, markdown: markdown, generation: generation, theme: theme,
            coordinator: coordinator)
    }
}

// MARK: - Full-pane .html artifact

/// The escape hatch for .html artifacts: the whole pane is one WKWebView
/// serving the local file from its own origin (siblings in the artifact's
/// directory resolve; nothing outside it does). The vendored mermaid.js + an
/// init script are injected so `<pre class="mermaid">` blocks render without
/// the page shipping its own renderer. `generation` bumps on external file
/// change to force a reload.
struct HTMLCanvasView: View {
    let url: URL
    let generation: Int
    let markTool: CanvasMarkTool
    let showsMark: Bool
    let onSelection: (CanvasPageSelection) -> Void
    /// The operator pressing Reload on the notice — a counter, not a flag, so pressing it twice
    /// reloads twice and a demand can never be missed by arriving in the same render as the
    /// answer that raised it. The same shape as `CanvasModel.addressFocus` and `generation`.
    let reloadDemand: Int
    /// What the page said about an offered update, on its way to the notice strip.
    let onUpdate: (CanvasUpdateAnswer) -> Void
    /// What the page said about **itself**, on its way to the latch beside the artifact (#110).
    /// A different callback from `onSelection` carrying a different type, because they are
    /// different claims — one about the operator, one about the page.
    let onState: (CanvasPageState) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HTMLCanvasWebView(
            url: url,
            generation: generation,
            markTool: markTool,
            showsMark: showsMark,
            theme: colorScheme == .dark ? .dark : .light,
            onSelection: onSelection,
            reloadDemand: reloadDemand,
            onUpdate: onUpdate,
            onState: onState
        )
    }
}

/// How a `.html` canvas's webview is built, and when it reloads. The two decisions
/// `HTMLCanvasWebView` below hands to SwiftUI — named here so that something which is not
/// SwiftUI can make them too.
///
/// **Split out for #261, and the bug is the argument.** A sibling-only edit reached the page
/// through nothing at all: `WorkbenchModel.offer` declined to refresh an open pane, and the
/// pane's own `FileWatcher` was never watching the sibling. Each half was covered on its own
/// and the join was not — #216's shape exactly — and the join cannot be driven through an
/// `NSViewRepresentable`, because `NSViewRepresentableContext` has no public initializer. So
/// what a test needs is here and the representable calls it. A test that stood up its own
/// `WKWebViewConfiguration` and its own reload rule would be a second spelling of both, and
/// would agree with the bug rather than catch it.
@MainActor
enum HTMLCanvasPage {
    /// A webview on the artifact's own `helm-canvas://` origin, with the annotation bridge
    /// installed and `coordinator` as its navigation delegate. Loads nothing by itself —
    /// `load` is the only thing that navigates.
    static func makeWebView(
        for path: StandardizedPath, coordinator: CanvasFileCoordinator
    )
        -> WKWebView
    {
        let configuration = WKWebViewConfiguration()
        let artifact = URL(fileURLWithPath: path.value)
        // Read straight from disk per request: the artifact IS the document here, and a
        // reload is meant to show what the agent just wrote.
        configuration.setURLSchemeHandler(
            CanvasSchemeHandler(artifact: artifact) {
                try? Data(contentsOf: artifact)
            },
            forURLScheme: CanvasAddress.scheme
        )
        coordinator.installBridge(on: configuration.userContentController)
        // **Only here, and not on the markdown canvas** (#110). An `.html` artifact is read
        // straight from disk, so its own scripts run and one of them may report state; a
        // markdown canvas is a page helm *generates*, with `marked` writing the artifact into
        // `innerHTML` where a `<script>` never executes — the same scoping, and the same
        // argument, as #109's update offer. It is a rule about where the capability is useful
        // rather than a boundary: markdown renders unsanitized, so an `onerror` attribute is
        // author JS that does run. The boundary that matters — that a page cannot forge an
        // operator's annotation — is `bridgeWorld`'s and is untouched either way.
        coordinator.installStateChannel(on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsMagnification = true
        return webView
    }

    /// (Re)loads when the file, its generation (external change), or the theme
    /// changes — **except that a generation move is now offered to the page first** (#109).
    ///
    /// **`generation` is the only thing that can say "the same path, different bytes"**, which
    /// is why a sibling edit has to reach `CanvasModel` before it can reach here: the path is
    /// unchanged and the theme is unchanged, so a bench that refreshes nothing leaves this
    /// function with no change to see and no reason to navigate (#261). `CanvasReloadKey` is
    /// where that is carried.
    ///
    /// **Three of the four reasons to move the key still navigate outright, and they have to.**
    /// A first load (`previous == nil`) has no page to offer anything to. A theme flip changes
    /// the *injected scripts*, which only take effect on a navigation, so a page that "applied"
    /// it would be left rendering its diagrams in the old mermaid theme. A different document
    /// is a different artifact. Only a generation move — the same artifact, rewritten — is an
    /// **update**, and that is the one this offers.
    static func load(
        _ webView: WKWebView, path: StandardizedPath, generation: Int, theme: CanvasTheme,
        coordinator: CanvasFileCoordinator
    ) {
        let key = CanvasReloadKey(theme: theme, generation: generation, document: path.value)
        let previous = coordinator.loadedKey
        guard previous != key else { return }
        coordinator.loadedKey = key

        let isUpdate = previous.map { $0.theme == theme && $0.document == path.value } ?? false
        guard isUpdate else {
            navigate(webView, path: path, theme: theme, coordinator: coordinator)
            return
        }
        coordinator.offer(
            CanvasUpdate(artifact: URL(fileURLWithPath: path.value), generation: generation),
            to: webView
        ) {
            navigate(webView, path: path, theme: theme, coordinator: coordinator)
        }
    }

    /// The operator answering the notice: load the artifact again whatever the page said.
    ///
    /// **Force is the operator's, and only the operator's.** helm never reaches this on its own
    /// — a page that declined an update or threw on one keeps its document until somebody at the
    /// pane decides otherwise, which is the whole of *"the gate belongs on the destructive
    /// action"*. The counter is compared rather than a flag consumed so that a demand cannot be
    /// swallowed by arriving in the same SwiftUI update as the answer that raised it.
    static func reloadOnDemand(
        _ demand: Int, _ webView: WKWebView, path: StandardizedPath, theme: CanvasTheme,
        coordinator: CanvasFileCoordinator
    ) {
        guard coordinator.reloadDemand != demand else { return }
        coordinator.reloadDemand = demand
        // Nothing has ever been loaded, so there is no document to take away and no page to
        // protect. **Unreachable from the representable**, and said plainly rather than left to
        // read as a live guard: `makeNSView` and `updateNSView` both call `load` first, and
        // `load` leaves `loadedKey` set on every path. It is here for a caller that has not,
        // which is what a `static` on an `enum` invites.
        guard coordinator.loadedKey != nil else { return }
        navigate(webView, path: path, theme: theme, coordinator: coordinator)
    }

    /// Actually take the document away and load it again. Scripts are re-armed per load so a
    /// theme flip re-renders the page's diagrams in the matching mermaid theme.
    ///
    /// **Split out of `load` by #109, and `forgetPushedState` came with it deliberately.** What
    /// that call resets is *what the page has been told* — the held tool, whether ink is up —
    /// and the only thing that makes those stale is the JS context being destroyed, which is a
    /// navigation. An offer the page applies destroys nothing, so resetting there would tell the
    /// page its tool again for no reason and, worse, would leave `markShown` claiming false
    /// while the operator is still looking at their own ink.
    private static func navigate(
        _ webView: WKWebView, path: StandardizedPath, theme: CanvasTheme,
        coordinator: CanvasFileCoordinator
    ) {
        coordinator.forgetPushedState()

        let controller = webView.configuration.userContentController
        // `removeAllUserScripts` takes the annotation script with it, so it is re-added
        // below. Forgetting that is how annotation would silently die the first time the
        // operator switched appearance.
        controller.removeAllUserScripts()
        if let mermaidJS = CanvasHTML.vendoredMermaid() {
            controller.addUserScript(
                WKUserScript(
                    source: mermaidJS,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
            controller.addUserScript(
                WKUserScript(
                    source: CanvasHTML.htmlArtifactInitScript(theme: theme),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }
        coordinator.addAnnotationScript(to: controller)
        guard let address = CanvasAddress.url(for: path) else { return }
        webView.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData))
    }
}

private struct HTMLCanvasWebView: NSViewRepresentable {
    let url: URL
    let generation: Int
    let markTool: CanvasMarkTool
    let showsMark: Bool
    let theme: CanvasTheme
    let onSelection: (CanvasPageSelection) -> Void
    let reloadDemand: Int
    let onUpdate: (CanvasUpdateAnswer) -> Void
    let onState: (CanvasPageState) -> Void

    private var path: StandardizedPath { StandardizedPath(url) }

    func makeCoordinator() -> CanvasFileCoordinator {
        let coordinator = CanvasFileCoordinator(
            host: CanvasAddress.host(for: path), onAnnotation: onSelection)
        coordinator.onUpdate = onUpdate
        // Set before `makeNSView` builds the webview, so a page that reports in its very first
        // inline script has somewhere for that report to land.
        coordinator.onState = onState
        // Seeded, not left at zero. A demand is a *rise* against what this coordinator has
        // already seen, and SwiftUI can build a fresh one for a pane whose model has pressed
        // Reload before — which against a zero would read as a demand nobody made and load the
        // document a second time, immediately after `makeNSView` loaded it.
        coordinator.reloadDemand = reloadDemand
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = HTMLCanvasPage.makeWebView(for: path, coordinator: context.coordinator)
        load(webView, coordinator: context.coordinator)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: CanvasFileCoordinator) {
        coordinator.removeBridge(from: webView.configuration.userContentController)
        coordinator.removeStateChannel(from: webView.configuration.userContentController)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
        HTMLCanvasPage.reloadOnDemand(
            reloadDemand, webView, path: path, theme: theme, coordinator: context.coordinator)
        context.coordinator.pushTool(markTool, theme: theme, to: webView)
        context.coordinator.showMark(showsMark, in: webView)
    }

    private func load(_ webView: WKWebView, coordinator: CanvasFileCoordinator) {
        HTMLCanvasPage.load(
            webView, path: path, generation: generation, theme: theme, coordinator: coordinator)
    }
}

// MARK: - Shared coordinator

/// Navigation policy for both artifact web views, plus the annotation bridge's plumbing —
/// and nothing but plumbing. What the page sent is validated by `CanvasAnnotation.decode`,
/// and *who sent it* by `CanvasAddress.accepts`; both are pure and testable, where a
/// `WKScriptMessage` is not.
///
/// Local-only enforcement lives here: any navigation that is not this artifact's own
/// `helm-canvas://` origin is cancelled — a link in a document or an .html page's remote
/// reference goes nowhere.
@MainActor
final class CanvasFileCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    /// The world helm's own script and the bridge share, and no page script can reach.
    ///
    /// `add(_:name:)` without a world registers into the **page content world**, where any
    /// script in the document — including one an artifact fetched, or an injected
    /// `<script>` — can post to the handler. Naming a world scopes both halves: helm's
    /// annotation script is injected `in:` it and the handler is registered
    /// `contentWorld:` it, so a page's own JS sees no `helmCanvas` at all.
    static let bridgeWorld = WKContentWorld.world(name: "helm-canvas-bridge")

    var loadedKey: CanvasReloadKey?
    /// The last reload the operator asked for, so a rising counter is a new demand and an
    /// unchanged one is ordinary SwiftUI churn. Starts at zero to match `CanvasModel`'s, so a
    /// pane that has never shown the notice never navigates for this reason.
    var reloadDemand = 0
    /// What the page said about an offered update, on its way to the notice strip. **A closure
    /// rather than a delegate call**, for `CanvasModel.onSourceChange`'s reason one file over:
    /// this object is SwiftUI's, made in `makeCoordinator`, and the model outlives it.
    var onUpdate: ((CanvasUpdateAnswer) -> Void)?
    /// What the page said about itself, on its way to the latch (#110). Set by the
    /// representable exactly as `onUpdate` is; nil on a coordinator built without one, where a
    /// report is dropped rather than crashing a pane over a page's own chatter.
    var onState: ((CanvasPageState) -> Void)?
    /// The page-world receiver, held here because `add(_:contentWorld:name:)` retains only the
    /// weak proxy. Its lifetime is the coordinator's, which is the webview's.
    private var stateChannel: CanvasStateChannel?
    /// The tool the page was last told about, or nil when the page has not been told at
    /// all — which includes every fresh document. A change is pushed with
    /// `evaluateJavaScript` rather than folded into `loadedKey`, because reloading to switch
    /// tools would throw away the scroll position, and a canvas is something you are part-way
    /// down when you decide to mark it.
    private(set) var pushedTool: CanvasMarkTool?
    /// The appearance the page was last told to paint a text mark in, or nil for the same reason
    /// `pushedTool` is (#308).
    ///
    /// **Today this term never decides anything, and it is kept anyway.** `theme` is part of
    /// `CanvasReloadKey`, so a flip is a navigation, and both load paths call
    /// `forgetPushedState()` on the way — which nils `pushedTool` too, so the tool half of the
    /// guard has already fired by the time this one is consulted. What it buys is that the fact
    /// it leans on lives in *another type*: drop this and the day a theme flip becomes something
    /// the page survives, helm would push a tool and no colour, and the failure would be a mark
    /// painted a whole appearance out of date with nothing to catch it.
    /// `CanvasHTMLTests.testAThemeFlipIsANavigationSoNoPaintedMarkOutlivesItsTint` pins the fact;
    /// this is the guard that makes being wrong about it survivable.
    private var pushedTheme: CanvasTheme?
    /// Whether the page currently holds a mark. Starts false: a fresh document has no ink.
    private var markShown = false
    /// The generated document the scheme handler should serve on the next request. Only
    /// the markdown canvas stages one; the .html canvas reads its artifact from disk.
    var stagedDocument: Data?

    /// Which canvas this coordinator belongs to. A message whose origin is not this host
    /// is not this canvas's message.
    private let host: String
    private let onAnnotation: (CanvasPageSelection) -> Void
    private lazy var proxy = WeakScriptMessageProxy(self)

    init(host: String, onAnnotation: @escaping (CanvasPageSelection) -> Void) {
        self.host = host
        self.onAnnotation = onAnnotation
    }

    /// Tell the page which tool is held. **Into `bridgeWorld`, never the page world.**
    /// `evaluateJavaScript(_:)` without a world runs in `WKContentWorld.page`, and the
    /// annotation script lives in a named world (#164) whose `window` is a different object
    /// — so the plain overload sets the global somewhere the script cannot see it and the
    /// tool stays `select` forever. The toolbar highlights, and nothing else happens.
    /// Everything helm says to the page goes through the named world, never the page's own.
    /// Stated once here rather than left as a fact a reader has to notice by comparing two
    /// call sites — getting it wrong made #190's whole feature silently inert.
    private func evaluate(_ script: String, in webView: WKWebView) {
        webView.evaluateJavaScript(
            script, in: nil, in: Self.bridgeWorld, completionHandler: { _ in })
    }

    func pushTool(_ tool: CanvasMarkTool, theme: CanvasTheme, to webView: WKWebView) {
        guard pushedTool != tool || pushedTheme != theme else { return }
        pushedTool = tool
        pushedTheme = theme
        evaluate(CanvasHTML.setMarkTool(tool, theme: theme), in: webView)
    }

    /// **Point every image on the page at a URL this refresh has not used before** (#279).
    ///
    /// Into `bridgeWorld` like everything else helm says to a page, and that costs nothing here:
    /// content worlds share one DOM, so a script there can re-point an `<img>` without helm's
    /// name ever appearing in the artifact's own `window`.
    ///
    /// **The generation comes from `loadedKey` rather than from a parameter**, because that is
    /// the one place both delivery points already agree on which refresh is on screen — the
    /// counter `CanvasReloadKey` carries for exactly the reason this needs it: *"the same path,
    /// the same theme, different bytes on disk"*.
    ///
    /// **Generation 0 is never stamped.** It is the first document this webview has put up, so
    /// there is no earlier decode to defeat, and stamping would buy a second request for every
    /// image on the page in exchange for nothing. The honest cost of saying it that way: a
    /// webview SwiftUI rebuilds at a later generation stamps once for nothing — one extra read
    /// of a local file, on a path that has just built a whole `WKWebView`.
    ///
    /// **The answer is read rather than discarded, and that is why this does not use
    /// `evaluate(_:in:)`.** The script returns how many images it had to leave alone — a
    /// `srcset` it could not parse — and a picture helm knowingly failed to refresh is exactly
    /// the silent staleness #279 is about. Named in the log, never swallowed: the bridge's
    /// dropped messages are reported the same way, one screen up, for the same reason. There is
    /// no operator-facing surface for it on purpose — a strip over the artifact would report an
    /// author's `srcset` to somebody who cannot act on it, and `log show` reaches whoever can.
    func restampImages(in webView: WKWebView) {
        guard let generation = loadedKey?.generation, generation > 0 else { return }
        webView.evaluateJavaScript(
            CanvasHTML.restampImagesScript(generation: generation), in: nil, in: Self.bridgeWorld
        ) { result in
            guard case let .success(value) = result,
                let unreachable = (value as? NSNumber)?.intValue, unreachable > 0
            else { return }
            NSLog(
                "helm: canvas left \(unreachable) image(s) unstamped — a `srcset` helm could not "
                    + "read, so an edited picture there may still be the old one")
        }
    }

    /// Take the mark down when the comment field closes — submitted or dismissed. Pushed
    /// only on the transition, so an ordinary SwiftUI re-render never wipes a mark the
    /// operator is still looking at.
    func showMark(_ shows: Bool, in webView: WKWebView) {
        guard markShown != shows else { return }
        markShown = shows
        guard !shows else { return }
        evaluate(CanvasHTML.clearMarkScript(), in: webView)
    }

    /// **Offer the update to the page, and reload only if it has nobody to take it** (#109).
    ///
    /// **Into `WKContentWorld.page`, and this is the one thing helm says to a canvas that goes
    /// there.** Everything else — the held tool, taking the ink down — goes into `bridgeWorld`,
    /// and `evaluate(_:in:)` above exists to make that hard to get wrong. This is the exception
    /// and it is not a lapse: `window.helmCanvasUpdate` is defined by the *artifact*, whose
    /// scripts run in the page world, and a lookup in `bridgeWorld` would find nothing on every
    /// page that ever registered one — the same silent inertness #190 was.
    ///
    /// The completion handler is `@MainActor`, so the answer lands on the same actor the
    /// decision is made on: an offer cannot be overtaken by the reload it was racing.
    func offer(_ update: CanvasUpdate, to webView: WKWebView, reload: @escaping () -> Void) {
        webView.evaluateJavaScript(
            update.offerScript(), in: nil, in: .page
        ) { [weak self] result in
            let answer: CanvasUpdateAnswer =
                switch result {
                case let .success(value): CanvasUpdateAnswer.decode(value)
                case let .failure(error): .unreadable(error.localizedDescription)
                }
            self?.onUpdate?(answer)
            if answer.reloads {
                reload()
            } else if answer.restampsImages {
                // The branch a navigation can never reach, and the reason #279 is a script
                // rather than a rebuilt webview: this page kept its document, so nothing here
                // will fetch its images again unless helm asks it to.
                self?.restampImages(in: webView)
            }
        }
    }

    /// A load destroys the JS context, so whatever the page was told is gone with it.
    /// Without this the guard above sees "no change" and never re-pushes — the tool silently
    /// reverts to `select` on the next agent write, which is the ordinary way a canvas
    /// updates.
    func forgetPushedState() {
        pushedTool = nil
        pushedTheme = nil
        markShown = false
    }

    func installBridge(on controller: WKUserContentController) {
        controller.add(
            proxy, contentWorld: CanvasFileCoordinator.bridgeWorld,
            name: CanvasBridgePolicy.handlerName)
        addAnnotationScript(to: controller)
    }

    func addAnnotationScript(to controller: WKUserContentController) {
        controller.addUserScript(
            WKUserScript(
                source: CanvasHTML.annotationScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: CanvasFileCoordinator.bridgeWorld
            )
        )
    }

    /// Called from `dismantleNSView`, and that is the only place it can work from.
    /// `add(_:contentWorld:name:)` retains the handler **strongly** and the controller is
    /// reachable from the webview, so relying on the handler's own `deinit` cannot work —
    /// the cycle is precisely what stops `deinit` firing. The weak proxy and this call are
    /// both needed; neither alone is reliable.
    func removeBridge(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(
            forName: CanvasBridgePolicy.handlerName, contentWorld: CanvasFileCoordinator.bridgeWorld
        )
    }

    /// **Into `WKContentWorld.page`, on its own name, into its own object** (#110).
    ///
    /// This is the one thing helm lets an artifact's own JavaScript say to it, and every part of
    /// that sentence is load-bearing. The world is the page's because the *artifact's* scripts
    /// have to reach it — `bridgeWorld` is where they cannot, which is the whole of #164 — and
    /// the receiver is `CanvasStateChannel` rather than this object because a shared receiver
    /// would need a `switch` on `message.name`, and a switch is somewhere two destinations can
    /// be confused. `CanvasPageState`'s header is the full argument.
    func installStateChannel(on controller: WKUserContentController) {
        let channel = CanvasStateChannel(host: host) { [weak self] state in
            self?.onState?(state)
        }
        stateChannel = channel
        controller.add(
            WeakScriptMessageProxy(channel), contentWorld: .page,
            name: CanvasPageState.handlerName)
    }

    /// `removeBridge`'s twin, and needed for its reason: `add(_:contentWorld:name:)` retains its
    /// handler strongly, so nothing here can be left to a `deinit` that the retain is what
    /// prevents.
    func removeStateChannel(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(
            forName: CanvasPageState.handlerName, contentWorld: .page)
        stateChannel = nil
    }

    /// **The other half of #279: a navigation is not enough.** A fresh document asks for the
    /// same image URL and WebKit answers it with the copy it already decoded — measured in
    /// `CanvasSiblingFreshnessLiveTests`, on an `<img>` in the markup and on one built by script
    /// alike. So the images have to be re-pointed once the document is here.
    ///
    /// **Here rather than in `load`**, because `load` returns before the page exists: at this
    /// moment `marked` has run and every `<img>` it made is in the DOM. It fires on the
    /// operator's Reload too, which is what makes that button the honest route out of a decline.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        restampImages(in: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if let url, url.scheme == CanvasAddress.scheme || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    /// WebKit delivers script messages on the main thread, which is what makes
    /// `assumeIsolated` correct here rather than a hop that would let a second selection
    /// overtake the first.
    nonisolated func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            let frame = message.frameInfo
            guard
                CanvasAddress.accepts(
                    isMainFrame: frame.isMainFrame,
                    originScheme: frame.securityOrigin.protocol,
                    originHost: frame.securityOrigin.host,
                    expectedHost: host)
            else { return }
            switch CanvasPageSelection.decode(message.body) {
            case let .success(report):
                onAnnotation(report)
            case let .failure(refusal):
                // **Named, never silent.** A message the gate dropped without a word is exactly
                // #216 — every geometry mark refused here for months while both sides' tests
                // stayed green. There is no operator-facing surface for it (nothing was marked,
                // so there is no field to put a strip over), and inventing one would put a
                // notice on screen for a page bug the operator cannot act on. The log is what a
                // reader of `log show` can act on, and it names the kind.
                NSLog("helm: canvas dropped a bridge message — \(refusal.reason)")
            }
        }
    }
}

// MARK: - The page's own channel

/// Receives what an `.html` artifact says about itself, and **nothing else** (#110).
///
/// **A separate object from `CanvasFileCoordinator`, deliberately.** The coordinator is the
/// annotation bridge's receiver; putting this on it too would mean one
/// `userContentController(_:didReceive:)` branching on `message.name`, and that branch is the
/// one place the operator's channel and the page's channel could ever be mixed up. Two objects
/// is the version of *"the two destinations never merge"* that a later change cannot quietly
/// undo — there is no `else` here to fall into, and this type cannot construct a
/// `CanvasPageSelection` or reach `CanvasNotes` at all.
///
/// **The origin check is the same one, and is not optional.** A cross-origin iframe reaches a
/// page-world handler — measured, and recorded in the research pass — so a report is accepted
/// only from this canvas's own main frame. Without it one artifact could latch state onto
/// another's file.
@MainActor
final class CanvasStateChannel: NSObject, WKScriptMessageHandler {
    /// Which canvas this channel belongs to. A message whose origin is not this host is not
    /// this canvas's message.
    private let host: String
    private let onState: (CanvasPageState) -> Void

    init(host: String, onState: @escaping (CanvasPageState) -> Void) {
        self.host = host
        self.onState = onState
    }

    /// WebKit delivers script messages on the main thread, which is what makes `assumeIsolated`
    /// correct here rather than a hop that would let a later report overtake an earlier one —
    /// and this latch is latest-wins, so an out-of-order pair would leave the *older* state on
    /// disk with no way to tell.
    nonisolated func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            let frame = message.frameInfo
            guard
                CanvasAddress.accepts(
                    isMainFrame: frame.isMainFrame,
                    originScheme: frame.securityOrigin.protocol,
                    originHost: frame.securityOrigin.host,
                    expectedHost: host)
            else { return }
            switch CanvasPageState.decode(message.body) {
            case let .success(report):
                onState(report)
            case let .failure(refusal):
                // **Named, never silent** — the bridge's rule beside it, for #216's reason. And
                // no operator-facing surface: a page whose state report is malformed has said
                // nothing about the operator, so a strip over their artifact would be helm
                // reporting an artifact's bug to somebody who cannot act on it. `log show` can.
                NSLog("helm: canvas dropped a state report — \(refusal.reason)")
            }
        }
    }
}

// MARK: - What the page reported

/// A live selection on the canvas: the payload the comment field needs, before there is a
/// comment to make an annotation out of.
///
/// `body` stays raw so `CanvasAnnotation.decode` — the pure, tested validation — is the
/// one thing that ever interprets it. This carries only what the UI needs to place itself.
struct CanvasSelection {
    /// The untrusted body, handed to `CanvasAnnotation.decode` once there is a comment.
    let body: [String: Any]
    /// Where the selection is in the viewport, so the field can be anchored near it.
    /// Presentation only; never persisted, and never part of an anchor.
    let rect: CGRect

    init?(_ body: Any) {
        guard let payload = body as? [String: Any] else { return nil }
        self.body = payload
        let raw = payload["rect"] as? [String: Any] ?? [:]
        func number(_ key: String) -> CGFloat {
            CGFloat((raw[key] as? NSNumber)?.doubleValue ?? 0)
        }
        rect = CGRect(
            x: number("x"), y: number("y"), width: number("width"), height: number("height"))
    }
}

/// Everything the annotation bridge can say: there is a selection to comment on, or there
/// is not one any more — a click on the page that left nothing selected.
///
/// **A body that decodes to neither is dropped, not treated as `.cleared`.** A dismissal is
/// something the operator did; a payload helm does not recognise is a bug or an impostor,
/// and letting the second stand in for the first would make a malformed message close a
/// field the operator was typing in. A selection must carry text for the same reason in
/// reverse — a report with none would put an empty comment field over the page.
///
/// **`kind` is the discriminator and there is exactly one of it** (#109, #210's third seam).
/// Before it, this gate had to *infer* the shape from which fields were present — a selection
/// was "carries a non-empty top-level `text`", a dismissal was `{cleared: true}`, a geometry
/// mark was `{mark: …}` — and #216 is what that cost: an enclosure carries `targets` and a
/// relation carries `from`/`to`, neither carries `text`, so both were dropped here for months
/// while every decoder test stayed green. #216 patched the inference by admitting anything with
/// a `mark`; this replaces the inference. `Kind` is now the only question asked, `mark` is gone
/// from the wire rather than left beside `kind` as a second spelling of the same fact, and the
/// values it used to carry are kinds.
///
/// **An unknown kind is refused, and the refusal says so.** That is the whole point of a
/// discriminator: `Pane.Content` throws on a `kind` this build never heard of and `Slot` drops
/// the pane rather than guessing, and this is the same rule one seam over. `decode` returns a
/// `Result` rather than an optional so the coordinator can name what it dropped — a message
/// dropped in silence is #216's failure mode, not its fix.
enum CanvasPageSelection {
    case selected(CanvasSelection)
    case cleared

    /// Every message the page may post. Exhaustive by construction: a value not in here is a
    /// message this build does not understand, and understanding it is not something to guess
    /// at from the fields that happen to be present.
    ///
    /// Spelled identically in `Resources/canvas-annotation.js`, which cannot compile against
    /// this enum — `CanvasAnnotationScriptTests.testTheScriptAndSwiftStillAgreeOnEveryMessageKind`
    /// is the gate that holds the two halves together, and `allCases` is what lets it be a gate
    /// over *every* kind rather than a sample.
    enum Kind: String, CaseIterable {
        /// A text highlight — helm's behaviour since #39, and the only kind before #112.
        case selection
        /// A click that left nothing selected: the canvas's click-elsewhere-to-dismiss (#165).
        case cleared
        /// A tap (#112).
        case point
        /// An arrow (#112).
        case relation
        /// A circle or box (#112).
        case enclosure
    }

    /// Why a body was not a message. Carried rather than collapsed into `nil` so the drop can
    /// be logged in the operator's terms — "an unknown kind" and "a selection with no text" are
    /// a version skew and a bug in the page respectively, and telling them apart is the
    /// difference between #216 and a ticket somebody can act on.
    enum Refusal: Error, Equatable {
        case notAnObject
        case noKind
        case unknownKind(String)
        case malformed(Kind)

        var reason: String {
            switch self {
            case .notAnObject: "the body is not an object"
            case .noKind: "the message carries no `kind`"
            case let .unknownKind(kind): "`kind: \(kind)` is not a kind this helm understands"
            case let .malformed(kind): "a `\(kind.rawValue)` message with nothing helm can use"
            }
        }
    }

    static func decode(_ body: Any) -> Result<CanvasPageSelection, Refusal> {
        guard let payload = body as? [String: Any] else { return .failure(.notAnObject) }
        guard let raw = payload["kind"] as? String else { return .failure(.noKind) }
        guard let kind = Kind(rawValue: raw) else { return .failure(.unknownKind(raw)) }
        if kind == .cleared { return .success(.cleared) }
        // The one shape check that survives the move to a declared kind, and it is about the
        // FIELD rather than the anchor: a `selection` with no text would put an empty comment
        // box over the page. Whether any of these resolves to an anchor is
        // `CanvasAnnotation.decode`'s call at comment time — the same as it already was for a
        // plain selection with no id — so nothing else is inspected here.
        if kind == .selection {
            let text = (payload["text"] as? String) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.malformed(kind))
            }
        }
        guard let selection = CanvasSelection(payload) else { return .failure(.malformed(kind)) }
        return .success(.selected(selection))
    }
}

// MARK: - WeakScriptMessageProxy

/// Stands between `WKUserContentController` and the real handler, holding it weakly.
///
/// `add(_:name:)` retains its handler strongly, and the controller is retained by the
/// configuration, which is retained by the webview — so handler → model → webview closes
/// a cycle and the whole pane leaks. This breaks it.
@MainActor
final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var handler: (any WKScriptMessageHandler)?

    init(_ handler: any WKScriptMessageHandler) {
        self.handler = handler
    }

    nonisolated func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            handler?.userContentController(controller, didReceive: message)
        }
    }
}

import AppKit
import Combine
import Foundation
import HelmWire

/// A browser pane's live side: finds the shared browser, shows one of its tabs, and forwards
/// the operator's mouse and keyboard to it.
///
/// **Chrome is benchd's, never helm's** (#350). This asks benchd for a connection to it
/// (`browser/connect`, relayed on benchd's machine, M5c), and when there is none it waits — it
/// never starts a browser. Agents drive the same browser with Playwright at the same time; this
/// only shows it and takes input.
///
/// Cached per pane by `WorkbenchModel`, like a canvas, so a tab switch keeps the connection.
@MainActor
final class BrowserPaneModel: ObservableObject {
    enum Status: Equatable {
        /// Not connected, and why — shown in the pane.
        case waiting(String)
        case connecting
        case connected
    }

    @Published private(set) var status: Status = .connecting
    @Published private(set) var tabs = BrowserTabs()
    /// The shown tab, or one of its frames, is loading.
    @Published private(set) var loading = false
    /// Dialogs a page raised and nobody has answered yet, by target (#544). The one on show is
    /// drawn over the page; any other is a badge on its tab.
    @Published private(set) var dialogs: [String: BrowserDialog] = [:]
    /// Each tab's page zoom (⌘+, ⌘−, ⌘0; #544), by target. A tab at 100% has no entry.
    @Published private(set) var zoom: [String: Double] = [:]
    /// Bumped to ask the view to put the keyboard in the address field (⌘L, a new tab).
    @Published private(set) var addressRequests = 0
    /// Bumped to ask the view for its find field (⌘F, #549).
    @Published private(set) var findRequests = 0
    /// Something the pane could not do for the operator — an upload benchd refused — until he
    /// dismisses it.
    @Published private(set) var notice: String?
    /// What the browser downloaded while the pane watched (#549).
    let downloads: BrowserDownloads
    /// Pages asking for a file (#549).
    let uploads = BrowserUploads()
    let pageInput = BrowserPageInput()
    /// Links the operator ⌘-clicked before the browser was reachable, oldest first. Each
    /// opens as a tab once the pane connects, so a click made while benchd's browser is
    /// still starting is not lost.
    private(set) var pendingLinks: [URL] = []

    /// Frames go straight to the view, not through `@Published`: at up to 60 a second,
    /// a SwiftUI re-render per frame would cost more than the frame.
    weak var surface: BrowserSurfaceView? {
        didSet { if let frame = lastFrame { surface?.show(frame) } }
    }

    /// benchd, or nil when this helm has none to ask (the status bar says why).
    private let endpoint: BenchEndpoint?
    private var connection: CDPConnection?
    private var session: String?
    /// Which tab each attached session is on: the shown tab's, and any held for its dialog.
    private var sessionTargets: [String: String] = [:]
    private var watch: Task<Void, Never>?
    private var viewport = Viewport(size: CGSize(width: 1280, height: 800), scale: 2)
    private var viewportTask: Task<Void, Never>?
    private var lastFrame: BrowserFrame?
    /// Frames of the shown tab between `frameStartedLoading` and `frameStoppedLoading`.
    private var loadingFrames: Set<String> = []
    /// Whether this connection's tab list is in. `Target.setDiscoverTargets` replays a
    /// `targetCreated` for every tab that already exists, and those must not read as tabs an
    /// agent just opened, so target events wait for the list.
    private var listed = false

    struct Viewport: Equatable {
        var size: CGSize
        var scale: CGFloat
    }

    init(endpoint: BenchEndpoint?) {
        self.endpoint = endpoint
        downloads = BrowserDownloads(endpoint: endpoint)
        pageInput.isCurrent = { [weak self] destination in
            self?.connection === destination.connection
                && self?.inputSession == destination.session
        }
        pageInput.failed = { [weak self] message in self?.notice = message }
        startWatching()
    }

    /// The pane is gone for good. Nothing is done to the browser: closing a pane closes a
    /// view onto it, not the browser agents may be using.
    func close() {
        watch?.cancel()
        watch = nil
        viewportTask?.cancel()
        pageInput.reset()
        connection?.close()
        connection = nil
    }

    // MARK: - Finding the browser

    /// Ask benchd for the browser once a second while disconnected, and for the tabs' titles
    /// once a second while connected. A refused ask is one short round trip, and it is the only
    /// signal there is: benchd answers with a connection once a browser runs, and says why not
    /// until then.
    private func startWatching() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if connection == nil { connect() } else if listed { refreshTitles() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The status stays what it was until benchd answers, so a pane waiting for a browser does
    /// not flicker to "connecting" once a second.
    private func connect() {
        guard let endpoint else {
            status = .waiting(
                "helm has no benchd to ask for the shared browser; the status bar says why.")
            return
        }
        let connection = CDPConnection(endpoint: endpoint)
        self.connection = connection
        connection.onEvent = { [weak self] event in self?.handle(event) }
        connection.onClose = { [weak self, weak connection] ending in
            guard let self, self.connection === connection else { return }
            self.connection = nil
            self.session = nil
            self.sessionTargets = [:]
            self.dialogs = [:]
            self.pageInput.reset()
            self.listed = false
            switch ending {
            case let .refused(why):
                self.status = .waiting(Self.waiting(why))
            case let .lost(why):
                self.status = .waiting(
                    "Lost the shared browser (\(why)). Waiting for it to come back.")
            }
        }
        connection.open()
        Task {
            do {
                // Discovery first, so a tab opened from here on is either in the list or an
                // event after it. One opened in the instant between is picked up by its next
                // `targetInfoChanged`, which `changed` treats as a creation.
                try await connection.call("Target.setDiscoverTargets", Discover(discover: true))
                // Downloads land where Chrome puts them anyway; this only has Chrome say so.
                try? await connection.call(
                    "Browser.setDownloadBehavior",
                    DownloadBehavior(behavior: "default", eventsEnabled: true))
                let reported = try await connection.call(
                    "Target.getTargets", returning: TargetInfos.self)
                listed = true
                apply(tabs.replaceAll(with: reported.targetInfos))
                status = .connected
                openPendingLinks()
            } catch {
                connection.close("could not read the browser's tabs: \(error)")
            }
        }
    }

    /// The strip's titles, asked for again (`BrowserTabs.retitle`). One short round trip a
    /// second, on the tick that already watches the connection.
    private func refreshTitles() {
        guard let connection else { return }
        Task {
            guard
                let reported = try? await connection.call(
                    "Target.getTargets", returning: TargetInfos.self)
            else { return }
            tabs.retitle(from: reported.targetInfos)
        }
    }

    /// What the pane says while benchd has no browser to give it: benchd's own sentence, which
    /// names the command that starts one.
    private static func waiting(_ why: String) -> String {
        guard let first = why.first else { return why }
        return first.uppercased() + why.dropFirst() + ". This pane connects when it appears."
    }

    // MARK: - Events

    private func handle(_ event: CDPConnection.Event) {
        pageInput.handle(event)
        switch event.method {
        case "Page.screencastFrame":
            guard event.sessionId == session, let frame = event.params(ScreencastFrame.self) else {
                return
            }
            connection?.send(
                "Page.screencastFrameAck", FrameAck(sessionId: frame.sessionId), session: session)
            guard let image = BrowserFrame(frame) else { return }
            lastFrame = image
            surface?.show(image)
        case "Target.targetCreated" where listed:
            if let info = event.params(TargetEvent.self) { apply(tabs.created(info.targetInfo)) }
        case "Target.targetInfoChanged" where listed:
            if let info = event.params(TargetEvent.self) { apply(tabs.changed(info.targetInfo)) }
        case "Target.targetDestroyed" where listed:
            if let gone = event.params(TargetGone.self) {
                zoom[gone.targetId] = nil
                dialogs[gone.targetId] = nil
                sessionTargets = sessionTargets.filter { $0.value != gone.targetId }
                apply(tabs.destroyed(gone.targetId))
            }
        case "Page.javascriptDialogOpening", "Page.javascriptDialogClosed":
            handleDialog(event)
        case "Browser.downloadWillBegin", "Browser.downloadProgress":
            downloads.handle(event)
        case "Page.fileChooserOpened":
            handleChooser(event)
        case "Page.frameNavigated":
            handleNavigation(event)
        case "Page.frameStartedLoading", "Page.frameStoppedLoading":
            handleLoading(event)
        default:
            break
        }
    }

    /// A dialog opening or closing in the shown tab, or in one held for its dialog (#544).
    private func handleDialog(_ event: CDPConnection.Event) {
        guard let held = event.sessionId, let target = sessionTargets[held] else { return }
        if event.method == "Page.javascriptDialogOpening" {
            if let opening = event.params(DialogOpening.self) {
                if held == session { pageInput.reset() }
                dialogs[target] = BrowserDialog(opening, session: held)
            }
            return
        }
        // Closed, whoever answered: the operator here, or an agent's Playwright on the same tab.
        dialogs[target] = nil
        if held == session {
            // The page runs again; restart its frames.
            Task { await fit(target: target, session: held) }
        } else {
            release(held)
        }
    }

    private func apply(_ decision: BrowserTabs.Decision) {
        switch decision {
        case .stay: break
        case let .show(target): attach(to: target)
        case .openBlank: createTab("about:blank")
        }
    }

    /// A tab this pane asked for: shown once the browser says which it is (`ownCreated`), and
    /// never marked as opened from outside.
    private func createTab(_ url: String) {
        guard let connection else { return }
        Task {
            guard
                let created = try? await connection.call(
                    "Target.createTarget", CreateTarget(url: url), returning: Created.self)
            else { return }
            apply(tabs.ownCreated(created.targetId))
        }
    }

    /// Show one tab: detach from the old one, attach to this one, size it to the pane and
    /// start its screencast.
    private func attach(to target: String) {
        guard let connection else { return }
        let previous = session
        session = nil
        pageInput.reset()
        loadingFrames.removeAll()
        loading = false
        Task {
            // A session holding a dialog stays attached: it is the only one that can answer,
            // and detaching it leaves the tab frozen for good (measured, #544).
            if let previous, !dialogs.values.contains(where: { $0.session == previous }) {
                connection.send("Page.stopScreencast", session: previous)
                release(previous)
            }
            if let held = dialogs[target]?.session {
                // Its page is stopped, so there is nothing to fit or draw until it is answered;
                // the close event fits it then.
                session = held
                connection.send("Page.bringToFront", session: held)
                lastFrame = nil
                surface?.clear()
                return
            }
            do {
                let attached = try await connection.call(
                    "Target.attachToTarget", Attach(targetId: target, flatten: true),
                    returning: Attached.self)
                // Another switch may have started while this one waited.
                guard tabs.showing == target else {
                    connection.send(
                        "Target.detachFromTarget", Detach(sessionId: attached.sessionId))
                    return
                }
                session = attached.sessionId
                sessionTargets[attached.sessionId] = target
                try await connection.call("Page.enable", session: attached.sessionId)
                // A file input then reports to the pane rather than doing nothing (#549).
                connection.send(
                    "Page.setInterceptFileChooserDialog", Intercept(enabled: true),
                    session: attached.sessionId)
                connection.send("Page.bringToFront", session: attached.sessionId)
                await fit(target: target, session: attached.sessionId)
            } catch {
                // The tab closed mid-attach; its destroy event decides what to show next.
            }
        }
    }

    private func release(_ held: String) {
        sessionTargets[held] = nil
        connection?.send("Target.detachFromTarget", Detach(sessionId: held))
    }

    /// Make the tab the pane's size, at the pane's pixel density, and (re)start its frames.
    ///
    /// **The window is resized, not only the page emulated.** An emulated viewport exists only
    /// while this pane is attached, so agents would lay out one page while the operator saw
    /// another; a window the pane's size is the same page for both. The metrics override on top
    /// carries the pane's pixel ratio — measured, a ratio with width and height left at 0 is
    /// ignored — so a retina pane is sharp.
    private func fit(target: String, session: String) async {
        guard let connection else { return }
        // Zoom is Chrome's own kind: the page lays out in pane ÷ zoom CSS pixels, each drawn
        // zoom times larger, so it reflows and `devicePixelRatio` says so, as it does in Chrome.
        // Input needs nothing: it maps through the frame's own page size.
        let factor = zoom[target] ?? 1
        let size = viewport.size
        let width = max(Int((size.width / factor).rounded()), 200)
        let height = max(Int((size.height / factor).rounded()), 150)
        let scale = viewport.scale * factor
        if let window = try? await connection.call(
            "Browser.getWindowForTarget", WindowFor(targetId: target), returning: WindowId.self)
        {
            // A headless window still reserves room for browser UI it does not draw, so the
            // page is smaller than the window. Ask the page how much, and grow the window by
            // that, so the page is exactly the pane.
            let inset = try? await connection.call(
                "Runtime.evaluate",
                Evaluate(
                    expression: "[outerWidth - innerWidth, outerHeight - innerHeight]"
                        + ".map(n => Number.isFinite(n) ? Math.max(0, Math.round(n)) : 0)",
                    returnByValue: true),
                session: session, returning: Evaluated<[Int]>.self)
            let extra = inset?.result.value ?? []
            let (dw, dh) = extra.count == 2 ? (extra[0], extra[1]) : (0, 0)
            try? await connection.call(
                "Browser.setWindowBounds",
                SetBounds(
                    windowId: window.windowId, bounds: .init(width: width + dw, height: height + dh)
                ))
        }
        try? await connection.call(
            "Emulation.setDeviceMetricsOverride",
            Metrics(
                width: width, height: height, deviceScaleFactor: Double(scale), mobile: false),
            session: session)
        connection.send("Page.stopScreencast", session: session)
        try? await connection.call(
            "Page.startScreencast",
            Screencast(
                format: "jpeg", quality: 85,
                maxWidth: Int(CGFloat(width) * scale), maxHeight: Int(CGFloat(height) * scale),
                everyNthFrame: 1),
            session: session)
    }

    // MARK: - From the view

    func viewportChanged(size: CGSize, scale: CGFloat) {
        let next = Viewport(size: size, scale: scale)
        guard next != viewport, size.width > 0, size.height > 0 else { return }
        viewport = next
        // A live resize reports every frame of the drag; fit once it settles.
        viewportTask?.cancel()
        viewportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let session = self.session,
                let target = self.tabs.showing
            else { return }
            await self.fit(target: target, session: session)
        }
    }

    func navigate(to typed: String) {
        guard let url = BrowserAddress.url(from: typed) else { return }
        connection?.send("Page.navigate", Navigate(url: url), session: session)
    }

    func goBack() { evaluate("history.back()") }
    func goForward() { evaluate("history.forward()") }
    func reload() { connection?.send("Page.reload", session: session) }
    func stopLoading() { connection?.send("Page.stopLoading", session: session) }

    func show(tab target: String) { apply(tabs.show(target)) }

    /// ⌘1–⌘8 pick a tab by position, and ⌘9 the last one, as in Chrome.
    func show(tabAt index: Int) {
        let all = tabs.tabs
        guard let tab = index >= 8 ? all.last : (all.indices.contains(index) ? all[index] : nil)
        else { return }
        show(tab: tab.targetId)
    }

    /// A new blank tab, shown, with the keyboard in its address field — Chrome's ⌘T.
    func newTab() {
        createTab("about:blank")
        focusAddress()
    }

    /// Closes the tab in the shared browser. Its destroy event decides what shows next.
    func close(tab target: String) {
        connection?.send("Target.closeTarget", CloseTarget(targetId: target))
    }

    func focusAddress() { addressRequests += 1 }

    /// The operator's answer to the dialog on show: OK or Cancel, and a `prompt`'s text. The
    /// dialog leaves `dialogs` when Chrome says it closed, not before.
    func answer(accept: Bool, text: String? = nil) {
        guard let target = tabs.showing, let dialog = dialogs[target] else { return }
        connection?.send(
            "Page.handleJavaScriptDialog",
            HandleDialog(accept: accept, promptText: dialog.kind == .prompt ? text : nil),
            session: dialog.session)
    }

    /// Zoom the tab on show a step in or out, or back to 100%, and lay it out again.
    func zoom(_ step: FontSizeStep) {
        guard let target = tabs.showing, let session else { return }
        let next = BrowserZoom.step(from: zoom[target] ?? 1, step)
        zoom[target] = next == 1 ? nil : next
        // A page stopped under a dialog is fitted when the dialog closes.
        guard dialogs[target] == nil else { return }
        Task { await fit(target: target, session: session) }
    }

    func toggleFollow() { tabs.follow.toggle() }

    /// A browser key (#542), from the pane holding the keyboard (`BrowserKeyboard`).
    func perform(_ command: BrowserCommand) {
        switch command {
        case .newTab: newTab()
        case .closeTab: if let shown = tabs.showing { close(tab: shown) }
        case .focusAddress: focusAddress()
        case .reload: reload()
        case .back: goBack()
        case .forward: goForward()
        case let .showTab(index): show(tabAt: index)
        case let .zoom(step): zoom(step)
        case .find: findRequests += 1
        }
    }

    /// Open `url` as a new tab of the shared browser — a ⌘-clicked link (#376). A new tab
    /// rather than the one on screen, so a page an agent is working in is not navigated away
    /// under it; the operator clicked it, so the pane shows it.
    func open(_ url: URL) {
        pendingLinks.append(url)
        if status == .connected { openPendingLinks() }
    }

    private func openPendingLinks() {
        guard connection != nil else { return }
        for url in pendingLinks { createTab(url.absoluteString) }
        pendingLinks.removeAll()
    }

    private func evaluate(_ expression: String) {
        connection?.send(
            "Runtime.evaluate", Evaluate(expression: expression, returnByValue: false),
            session: session)
    }
}

// MARK: - Find, files and loading

// In an extension so the class body stays the pane's connection and tabs; same file, so the
// private state is still the model's alone.
extension BrowserPaneModel {
    /// A frame of the shown tab started or stopped loading.
    private func handleLoading(_ event: CDPConnection.Event) {
        guard event.sessionId == session, let frame = event.params(FrameEvent.self) else {
            return
        }
        if event.method == "Page.frameStartedLoading" {
            loadingFrames.insert(frame.frameId)
        } else {
            loadingFrames.remove(frame.frameId)
        }
        if loading != !loadingFrames.isEmpty { loading = !loadingFrames.isEmpty }
    }

    private func handleNavigation(_ event: CDPConnection.Event) {
        guard event.sessionId == session,
            let navigation = event.params(FrameNavigation.self), navigation.frame.parentId == nil
        else { return }
        pageInput.reset()
    }

    /// A page on show asked for a file. Only one the operator's own click opened gets a panel
    /// (`BrowserUploads`); the chosen files go to the input as paths on benchd's machine.
    private func handleChooser(_ event: CDPConnection.Event) {
        guard let held = event.sessionId, held == session, let endpoint,
            let chooser = event.params(BrowserUploads.Chooser.self), uploads.operatorAsked
        else { return }
        uploads.answer(
            chooser, endpoint: endpoint,
            deliver: { [weak self] paths in
                self?.connection?.send(
                    "DOM.setFileInputFiles",
                    SetFiles(files: paths, backendNodeId: chooser.backendNodeId), session: held)
            },
            failed: { [weak self] why in self?.notice = why })
    }

    func dismissNotice() { notice = nil }

    /// The next match for `text` on the page on show, selected and scrolled into view by the
    /// page's own `window.find` (case-insensitive, wrapping). `fromTop` starts again from the top,
    /// as typing does. nil when there is no page to search: none on show, or one stopped under a
    /// dialog, where the evaluate would wait for the answer.
    func find(_ text: String, backwards: Bool, fromTop: Bool) async -> Bool? {
        guard let connection, let session = inputSession,
            let literal = try? String(data: JSONEncoder().encode(text), encoding: .utf8)
        else { return nil }
        let expression =
            "(() => { if (\(fromTop)) getSelection().removeAllRanges();"
            + " return window.find(\(literal), false, \(backwards), true); })()"
        let result = try? await connection.call(
            "Runtime.evaluate", Evaluate(expression: expression, returnByValue: true),
            session: session, returning: Evaluated<Bool>.self)
        return result?.result.value
    }

}
// MARK: - Input from the surface

extension BrowserPaneModel: BrowserInputSink {
    /// Where the operator's input goes: the shown tab, unless a dialog has stopped it. Chrome
    /// queues input sent to a stopped page and delivers it once the dialog is answered
    /// (measured, #544), so text typed at the page under a dialog would land in it afterwards.
    private var inputSession: String? {
        guard let shown = tabs.showing, dialogs[shown] == nil,
            let session, sessionTargets[session] == shown
        else { return nil }
        return session
    }

    func mouse(_ params: MouseEvent) {
        guard let connection, let inputSession else { return }
        if params.type == "mousePressed" { uploads.operatorActed() }
        pageInput.send(.mouse(params), to: .init(connection: connection, session: inputSession))
    }

    func key(_ params: KeyEvent) {
        guard let connection, let inputSession else { return }
        uploads.operatorActed()
        pageInput.send(.key(params), to: .init(connection: connection, session: inputSession))
    }

    func insertText(_ text: String) {
        guard let connection, let inputSession else { return }
        pageInput.send(.text(text), to: .init(connection: connection, session: inputSession))
    }

    func paste(_ payload: BrowserPaste) {
        guard let connection, let inputSession else { return }
        pageInput.send(.paste(payload), to: .init(connection: connection, session: inputSession))
    }

    func setComposition(_ text: String, selection: NSRange) {
        guard let connection, let session = inputSession else { return }
        pageInput.send(
            .composition(BrowserComposition(text: text, selection: selection)),
            to: .init(connection: connection, session: session))
    }

    func textCaretRect() async -> CGRect? {
        guard let connection, let session = inputSession else { return nil }
        return await pageInput.caret(to: .init(connection: connection, session: session))
    }

    /// A CDP call to the page the operator's input goes to: nil under a dialog, with no browser,
    /// or when the call fails. How `BrowserPointer.swift` asks the page about the pointer.
    func inputCall<Result: Decodable>(
        _ method: String, _ params: some Encodable, returning _: Result.Type
    ) async -> Result? {
        guard let connection, let session = inputSession else { return nil }
        return try? await connection.call(method, params, session: session, returning: Result.self)
    }

    /// The page's selection as text: a text field's selected range, else the document's. None
    /// under a dialog: the evaluate would wait for the answer and then overwrite the clipboard,
    /// maybe after the operator had copied something else.
    func selectedText() async -> String? {
        guard let connection, let session = inputSession else { return nil }
        let expression = """
            (() => { const a = document.activeElement;
              if (a && typeof a.selectionStart === 'number' && typeof a.value === 'string')
                return a.value.substring(a.selectionStart, a.selectionEnd);
              return String(getSelection()); })()
            """
        let result = try? await connection.call(
            "Runtime.evaluate", Evaluate(expression: expression, returnByValue: true),
            session: session, returning: Evaluated<String>.self)
        return result?.result.value
    }
}

// MARK: - Wire shapes

// The CDP shapes the pane sends and reads. File-level rather than nested, so the model's body
// is its behaviour.
private struct TargetInfos: Decodable { let targetInfos: [BrowserTab] }
private struct TargetEvent: Decodable { let targetInfo: BrowserTab }
private struct TargetGone: Decodable { let targetId: String }
private struct Discover: Encodable { let discover: Bool }
private struct CreateTarget: Encodable { let url: String }
private struct Created: Decodable { let targetId: String }
private struct CloseTarget: Encodable { let targetId: String }
private struct FrameEvent: Decodable { let frameId: String }
private struct FrameNavigation: Decodable {
    struct Frame: Decodable { let parentId: String? }
    let frame: Frame
}
private struct DownloadBehavior: Encodable {
    let behavior: String
    let eventsEnabled: Bool
}
private struct Intercept: Encodable { let enabled: Bool }
private struct SetFiles: Encodable {
    let files: [String]
    let backendNodeId: Int
}
private struct HandleDialog: Encodable {
    let accept: Bool
    let promptText: String?
}
private struct Attach: Encodable {
    let targetId: String
    let flatten: Bool
}
private struct Attached: Decodable { let sessionId: String }
private struct Detach: Encodable { let sessionId: String }
private struct WindowFor: Encodable { let targetId: String }
private struct WindowId: Decodable { let windowId: Int }
private struct SetBounds: Encodable {
    struct Bounds: Encodable {
        let width: Int
        let height: Int
    }
    let windowId: Int
    let bounds: Bounds
}
private struct Metrics: Encodable {
    let width: Int
    let height: Int
    let deviceScaleFactor: Double
    let mobile: Bool
}
private struct Screencast: Encodable {
    let format: String
    let quality: Int
    let maxWidth: Int
    let maxHeight: Int
    let everyNthFrame: Int
}
private struct FrameAck: Encodable { let sessionId: Int }
private struct Navigate: Encodable { let url: String }
struct Evaluate: Encodable {
    let expression: String
    let returnByValue: Bool
}
struct Evaluated<Value: Decodable>: Decodable {
    struct Remote: Decodable { let value: Value? }
    let result: Remote
}

// MARK: - Input wire shapes

/// What the surface sends in, shaped as CDP's `Input.dispatchMouseEvent`/`dispatchKeyEvent`.
extension BrowserPaneModel {
    struct MouseEvent: Encodable, Equatable {
        let type: String
        let x: Double
        let y: Double
        var button: String = "none"
        var buttons: Int = 0
        var clickCount: Int = 0
        var modifiers: Int = 0
        var deltaX: Double?
        var deltaY: Double?
    }

    /// Has no `nativeVirtualKeyCode`, on purpose. With one, Chrome on macOS builds a real
    /// `NSEvent` for the key, and a key the page leaves unhandled (a `b` on a page body) is
    /// redispatched through `NSApplication` back into the page, forever: 100% CPU and every tab
    /// frozen (#545). Playwright and Puppeteer never send it.
    struct KeyEvent: Encodable, Equatable {
        let type: String
        let modifiers: Int
        let key: String
        let code: String
        let windowsVirtualKeyCode: Int
        var text: String?
        var unmodifiedText: String?
        var autoRepeat: Bool?
        var commands: [String]?
    }
}

/// One screencast frame, decoded, with the page geometry it was taken at.
struct BrowserFrame {
    let image: CGImage
    /// The page's viewport in CSS pixels — what input coordinates are measured in.
    let pageSize: CGSize

    init(image: CGImage, pageSize: CGSize) {
        self.image = image
        self.pageSize = pageSize
    }

    init?(_ frame: ScreencastFrame) {
        guard let data = Data(base64Encoded: frame.data),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self.image = image
        pageSize = CGSize(width: frame.metadata.deviceWidth, height: frame.metadata.deviceHeight)
    }
}

struct ScreencastFrame: Decodable {
    struct Metadata: Decodable {
        let deviceWidth: Double
        let deviceHeight: Double
    }
    let data: String
    let metadata: Metadata
    let sessionId: Int
}

/// What the address field turns into a URL. A scheme is kept as typed; a bare local address
/// gets `http://`, anything else `https://`. A phrase with spaces is not guessed at — this is
/// not a search box.
enum BrowserAddress {
    static func url(from typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if text.contains("://") { return text }
        for scheme in ["about:", "data:", "chrome:", "file:"] where text.hasPrefix(scheme) {
            return text
        }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        if bare == "localhost" || bare == "127.0.0.1" || bare == "[::1]" { return "http://" + text }
        return "https://" + text
    }
}

import AppKit
import Combine
import Foundation
import HelmWire

/// A browser pane's live side: finds the shared browser, shows one of its tabs, and forwards
/// the operator's mouse and keyboard to it.
///
/// **Chrome is benchd's, never helm's** (#350). This connects to the endpoint benchd
/// publishes, and when there is none it waits — it never starts a browser. Agents drive the
/// same browser with Playwright at the same time; this only shows it and takes input.
///
/// Cached per pane by `WorkbenchModel`, like a canvas, so a tab switch keeps the connection.
@MainActor
final class BrowserPaneModel: ObservableObject, BrowserInputSink {
    enum Status: Equatable {
        /// Not connected, and why — shown in the pane.
        case waiting(String)
        case connecting
        case connected
    }

    @Published private(set) var status: Status = .connecting
    @Published private(set) var tabs = BrowserTabs()

    /// Frames go straight to the view, not through `@Published`: at up to 60 a second,
    /// a SwiftUI re-render per frame would cost more than the frame.
    weak var surface: BrowserSurfaceView? {
        didSet { if let frame = lastFrame { surface?.show(frame) } }
    }

    private let endpointURL: Result<URL, BenchRootError>
    private var connection: CDPConnection?
    private var session: String?
    private var watch: Task<Void, Never>?
    private var viewport = Viewport(size: CGSize(width: 1280, height: 800), scale: 2)
    private var viewportTask: Task<Void, Never>?
    private var lastFrame: BrowserFrame?

    struct Viewport: Equatable {
        var size: CGSize
        var scale: CGFloat
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        endpointURL = BenchRoot.resolve(environment: environment, home: home)
            .map(BrowserEndpoint.url(in:))
        startWatching()
    }

    /// The pane is gone for good. Nothing is done to the browser: closing a pane closes a
    /// view onto it, not the browser agents may be using.
    func close() {
        watch?.cancel()
        watch = nil
        viewportTask?.cancel()
        connection?.close()
        connection = nil
    }

    // MARK: - Finding the browser

    /// Poll the endpoint file once a second while disconnected. A file read a second is
    /// nothing, and it is the only signal there is: benchd writes the file when a browser
    /// comes up and removes it when it goes.
    private func startWatching() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if connection == nil { lookForBrowser() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func lookForBrowser() {
        let url: URL
        switch endpointURL {
        case let .failure(error):
            status = .waiting(error.sentence)
            return
        case let .success(found):
            url = found
        }
        switch BrowserEndpoint.read(at: url) {
        case .absent:
            status = .waiting(
                "No shared browser is running here. `bench browser start` starts one, and "
                    + "after `bench browser setup` it comes back when that window is quit (⌘Q); "
                    + "this pane connects when it appears.")
        case let .unreadable(why):
            status = .waiting(why)
        case let .found(endpoint):
            guard let ws = endpoint.webSocketURL else {
                status = .waiting("\(url.path) names no websocket")
                return
            }
            connect(to: ws)
        }
    }

    private func connect(to ws: URL) {
        status = .connecting
        let connection = CDPConnection(url: ws)
        self.connection = connection
        connection.onEvent = { [weak self] event in self?.handle(event) }
        connection.onClose = { [weak self, weak connection] reason in
            guard let self, self.connection === connection else { return }
            self.connection = nil
            self.session = nil
            self.status = .waiting(
                "Lost the shared browser (\(reason)). Waiting for it to come back.")
        }
        connection.open()
        Task {
            do {
                let listed = try await connection.call(
                    "Target.getTargets", returning: TargetInfos.self)
                try await connection.call("Target.setDiscoverTargets", Discover(discover: true))
                apply(tabs.replaceAll(with: listed.targetInfos))
                status = .connected
            } catch {
                connection.close("could not read the browser's tabs: \(error)")
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: CDPConnection.Event) {
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
        case "Target.targetCreated":
            if let info = event.params(TargetEvent.self) { apply(tabs.created(info.targetInfo)) }
        case "Target.targetInfoChanged":
            if let info = event.params(TargetEvent.self) { apply(tabs.changed(info.targetInfo)) }
        case "Target.targetDestroyed":
            if let gone = event.params(TargetGone.self) { apply(tabs.destroyed(gone.targetId)) }
        default:
            break
        }
    }

    private func apply(_ decision: BrowserTabs.Decision) {
        switch decision {
        case .stay: break
        case let .show(target): attach(to: target)
        case .openBlank:
            connection?.send("Target.createTarget", CreateTarget(url: "about:blank"))
        }
    }

    /// Show one tab: detach from the old one, attach to this one, size it to the pane and
    /// start its screencast.
    private func attach(to target: String) {
        guard let connection else { return }
        let previous = session
        Task {
            if let previous {
                connection.send("Page.stopScreencast", session: previous)
                connection.send("Target.detachFromTarget", Detach(sessionId: previous))
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
                try await connection.call("Page.enable", session: attached.sessionId)
                connection.send("Page.bringToFront", session: attached.sessionId)
                await fit(target: target, session: attached.sessionId)
            } catch {
                // The tab closed mid-attach; its destroy event decides what to show next.
            }
        }
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
        let size = viewport.size
        let width = max(Int(size.width.rounded()), 200)
        let height = max(Int(size.height.rounded()), 150)
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
                width: width, height: height, deviceScaleFactor: Double(viewport.scale),
                mobile: false),
            session: session)
        connection.send("Page.stopScreencast", session: session)
        try? await connection.call(
            "Page.startScreencast",
            Screencast(
                format: "jpeg", quality: 85,
                maxWidth: Int(CGFloat(width) * viewport.scale),
                maxHeight: Int(CGFloat(height) * viewport.scale), everyNthFrame: 1),
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

    func mouse(_ params: MouseEvent) {
        connection?.send("Input.dispatchMouseEvent", params, session: session)
    }

    func key(_ params: KeyEvent) {
        connection?.send("Input.dispatchKeyEvent", params, session: session)
    }

    func insertText(_ text: String) {
        connection?.send("Input.insertText", InsertText(text: text), session: session)
    }

    /// The page's selection as text: a text field's selected range, else the document's.
    func selectedText() async -> String? {
        guard let connection, let session else { return nil }
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

    func navigate(to typed: String) {
        guard let url = BrowserAddress.url(from: typed) else { return }
        connection?.send("Page.navigate", Navigate(url: url), session: session)
    }

    func goBack() { evaluate("history.back()") }
    func goForward() { evaluate("history.forward()") }
    func reload() { connection?.send("Page.reload", session: session) }

    func show(tab target: String) { apply(tabs.show(target)) }

    func newTab() {
        connection?.send("Target.createTarget", CreateTarget(url: "about:blank"))
    }

    private func evaluate(_ expression: String) {
        connection?.send(
            "Runtime.evaluate", Evaluate(expression: expression, returnByValue: false),
            session: session)
    }

    // MARK: - Wire shapes

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

    struct KeyEvent: Encodable, Equatable {
        let type: String
        let modifiers: Int
        let key: String
        let code: String
        let windowsVirtualKeyCode: Int
        let nativeVirtualKeyCode: Int
        var text: String?
        var unmodifiedText: String?
        var autoRepeat: Bool?
        var commands: [String]?
    }

    private struct TargetInfos: Decodable { let targetInfos: [BrowserTab] }
    private struct TargetEvent: Decodable { let targetInfo: BrowserTab }
    private struct TargetGone: Decodable { let targetId: String }
    private struct Discover: Encodable { let discover: Bool }
    private struct CreateTarget: Encodable { let url: String }
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
    private struct InsertText: Encodable { let text: String }
    private struct Navigate: Encodable { let url: String }
    private struct Evaluate: Encodable {
        let expression: String
        let returnByValue: Bool
    }
    private struct Evaluated<Value: Decodable>: Decodable {
        struct Remote: Decodable { let value: Value? }
        let result: Remote
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

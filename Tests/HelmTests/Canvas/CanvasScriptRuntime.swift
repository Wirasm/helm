import Foundation
import JavaScriptCore

@testable import Helm

/// Runs the annotation script — the real one, from `CanvasHTML.annotationScript()`, which is
/// the bytes WebKit is handed — against `canvas-dom-stub.js` in JavaScriptCore.
///
/// **This is the thing #197 was for.** While the script lived in a Swift string literal the
/// only test available was a substring check, and three consecutive PRs shipped a defect that
/// every one of those checks passed: #190's content world, #196's coordinate space, #208's
/// containment rule. Two is luck; three is the medium. A gesture driven through here fails on
/// what the script *does*.
///
/// **JavaScriptCore, not `WKWebView`.** JavaScriptCore is in the macOS SDK, needs no display,
/// no run loop and no main actor, so the gate still takes only the Swift toolchain — which
/// `AGENTS.md` asks for in as many words. What it does not carry is a layout engine, so
/// everything the stub reports about geometry is the stub's arithmetic and not a browser's:
/// see `canvas-dom-stub.js` for the two places that distinction was decided rather than
/// assumed. Anything about WebKit itself — content worlds, injection time, bracketed paste —
/// is out of reach here and stays a manual check.
final class CanvasScriptRuntime {
    private let context: JSContext
    private var exceptions: [String] = []

    /// - Parameter bridge: `false` drops `window.webkit` entirely, which is a URL canvas or
    ///   an artifact opened outside helm — the case #33 requires be untouched.
    init(bridge: Bool = true) throws {
        guard let context = JSContext() else {
            throw Failure.noContext
        }
        self.context = context
        context.exceptionHandler = { [weak self] _, value in
            self?.exceptions.append(value?.toString() ?? "unknown JS exception")
        }
        context.setObject(!bridge, forKeyedSubscript: "__helmNoBridge" as NSString)

        guard
            let stub = Bundle.module.url(forResource: "canvas-dom-stub", withExtension: "js"),
            let stubSource = try? String(contentsOf: stub, encoding: .utf8)
        else {
            throw Failure.noStub
        }
        context.evaluateScript(stubSource, withSourceURL: stub)
        try assertNoExceptions(stage: "the DOM stub")

        let script = CanvasHTML.annotationScript()
        guard !script.isEmpty else { throw Failure.noScript }
        // Named so a syntax error reports a line in the file an author would open.
        context.evaluateScript(script, withSourceURL: URL(fileURLWithPath: "canvas-annotation.js"))
        try assertNoExceptions(stage: "the annotation script")
    }

    enum Failure: Error {
        case noContext
        case noStub
        case noScript
        case javaScript(String)
    }

    private func assertNoExceptions(stage: String) throws {
        guard exceptions.isEmpty else {
            throw Failure.javaScript("\(stage): \(exceptions.joined(separator: "; "))")
        }
    }

    // MARK: Driving the page

    func setTool(_ tool: CanvasMarkTool) { call("setTool", tool.token) }

    func scroll(x: Double, y: Double) { call("scrollTo", x, y) }

    /// Page coordinates, which is what the operator's hand means and what the stroke stores.
    /// Returns whether the script called `preventDefault()` — the page taking the pointer over
    /// from the browser, which it may only do for a gesture it is actually going to draw.
    @discardableResult
    func mouse(_ type: String, _ x: Double, _ y: Double, button: Int = 0) -> Bool {
        call("mouse", type, x, y, button)?.toBool() ?? false
    }

    /// The whole gesture: press, a straight run of moves, release. `point` never moves, which
    /// is the one gesture with no travel.
    func drag(from start: (x: Double, y: Double), to end: (x: Double, y: Double), steps: Int = 4) {
        mouse("mousedown", start.x, start.y)
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            mouse(
                "mousemove", start.x + (end.x - start.x) * fraction,
                start.y + (end.y - start.y) * fraction)
        }
        mouse("mouseup", end.x, end.y)
    }

    /// A closed-ish loop round a page-coordinate rectangle, released short of where it began —
    /// a person circling something does not carefully meet the ends.
    func loop(around rect: (x: Double, y: Double, width: Double, height: Double)) {
        let corners = [
            (rect.x, rect.y),
            (rect.x + rect.width, rect.y),
            (rect.x + rect.width, rect.y + rect.height),
            (rect.x, rect.y + rect.height),
        ]
        mouse("mousedown", corners[0].0, corners[0].1)
        for corner in corners.dropFirst() { mouse("mousemove", corner.0, corner.1) }
        mouse("mouseup", corners[0].0, corners[0].1 + 6)
    }

    func tap(at point: (x: Double, y: Double)) {
        mouse("mousedown", point.x, point.y)
        mouse("mouseup", point.x, point.y)
    }

    /// Make the page an `.html` **artifact** rather than the markdown page helm generates: same
    /// DOM, minus helm's frame marker, because an artifact is read straight from disk and every
    /// element in it is the agent's own.
    func asHTMLArtifact() { call("asHTMLArtifact") }

    /// Put a mounted drawable board on the page — a container carrying `data-helm-surface`
    /// with a `<canvas>` inside it (#111). Opt-in, so no other test in this suite meets it.
    /// Its page-coordinate box is `boardBox`.
    func mountBoard() { call("mountBoard") }

    /// Where `mountBoard` puts the board, in page coordinates. Named once here rather than
    /// retyped per assertion — a stroke aimed at the wrong band would yield for the wrong
    /// reason and still pass.
    static let boardBox = (x: 20.0, y: 450.0, width: 700.0, height: 200.0)

    func select(id: String, text: String) { call("select", id, text) }

    /// Highlight inside a block the fixture gave no id, addressed by its own text — the only
    /// handle an id-less element has, and not having one is the whole of #215.
    func select(inBlockWithText block: String, text: String) {
        call("selectInBlock", block, text)
    }
    func blurWindow() { call("fireOnWindow", "blur") }
    func mouseLeaveDocument() { call("fireOnDocument", "mouseleave") }

    /// What Swift pushes when the comment field closes, run for real rather than asserted on.
    func evaluateFromSwift(_ javaScript: String) { context.evaluateScript(javaScript) }

    // MARK: Reading the page back

    /// Every message the page posted, in order, exactly as `WKScriptMessage.body` would
    /// present it: `NSDictionary`/`NSString`/`NSNumber` bridged out of JavaScriptCore.
    var posted: [[String: Any]] {
        let raw = helm?.objectForKeyedSubscript("posted")?.toArray() ?? []
        return raw.compactMap { $0 as? [String: Any] }
    }

    var lastPosted: [String: Any]? { posted.last }

    var hasMarkLayer: Bool { call("hasMarkLayer")?.toBool() ?? false }
    var markLayerStyle: String { call("markLayerStyle")?.toString() ?? "" }
    var ringCount: Int { Int(call("ringCount")?.toInt32() ?? 0) }
    var markLayerIDs: [String] { (call("markerIDs")?.toArray() as? [String]) ?? [] }

    struct Ink {
        var d: String
        var markerEnd: String?
    }

    var inkPaths: [Ink] {
        let raw = call("inkPaths")?.toArray() ?? []
        return raw.compactMap { entry in
            guard let entry = entry as? [String: Any], let d = entry["d"] as? String else {
                return nil
            }
            return Ink(d: d, markerEnd: entry["markerEnd"] as? String)
        }
    }

    @discardableResult
    func layOut(id: String, x: Double, y: Double, width: Double, height: Double) -> Bool {
        call("layOut", id, x, y, width, height)?.toBool() ?? false
    }

    @discardableResult
    func giveText(id: String, text: String) -> Bool {
        call("giveText", id, text)?.toBool() ?? false
    }

    func listenerCount(on target: String, for type: String) -> Int {
        Int(call("listenerCount", target, type)?.toInt32() ?? 0)
    }

    /// Globals the script publishes for Swift to call — the far half of `clearMarkScript()`
    /// and `setMarkTool(_:)`.
    func hasGlobal(_ name: String) -> Bool {
        context.objectForKeyedSubscript("window")?
            .objectForKeyedSubscript(name)?.isUndefined == false
    }

    /// Anything the page threw since the last check. Empty is the assertion.
    func drainExceptions() -> [String] {
        defer { exceptions = [] }
        return exceptions
    }

    // MARK: -

    private var helm: JSValue? { context.objectForKeyedSubscript("__helm") }

    @discardableResult
    private func call(_ name: String, _ arguments: Any...) -> JSValue? {
        helm?.objectForKeyedSubscript(name)?.call(withArguments: arguments)
    }
}

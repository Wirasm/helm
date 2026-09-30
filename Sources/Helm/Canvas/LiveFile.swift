import Foundation
import HelmWire
import WebKit

// MARK: - What the page may write

/// A page writing its live file (#532): the one JSON file beside an HTML canvas,
/// `<stem>.data.json` (`BenchLiveFile`), that the page and the agent both edit.
///
/// **The page names data, never a path.** The file is fixed by the canvas's own name, so an
/// artifact can write exactly one file, the one beside it that everybody can see by looking.
///
/// **And it names what it saw.** `base` is the bytes the page last read or was answered with, and
/// benchd writes only over those (`file/write`'s `unchanged`). A page that did not see the newest
/// version is answered `changed` with it, and replays its own change on top. That is the whole
/// concurrency story: nobody's write replaces a version its writer has not seen.
///
/// `kind` from the first message, on `AGENTS.md`'s rule, so a second kind is an addition.
struct CanvasDataWrite: Equatable {
    /// The handler an `.html` artifact posts to:
    /// `window.webkit.messageHandlers.helmCanvasData.postMessage(…)`, which answers with a
    /// promise. Page world, and deliberately not the annotation bridge's name or world: a page
    /// can write its own data, and still cannot forge the operator's mark (#164).
    static let handlerName = "helmCanvasData"
    static let kind = "canvas.data.write"

    /// The JSON helm writes: keys sorted, pretty, a trailing newline. The same data always
    /// writes the same bytes, so a page that writes what is already there changes nothing.
    let text: String
    /// What the page saw of the file: nil when there was none.
    let base: String?
    /// Whether the agent that opened the canvas is mailed about it. A page reporting its own
    /// state says `false`, so nobody is woken for it.
    let notify: Bool

    enum Refusal: Error, Equatable {
        case notAnObject
        case unknownKind(String?)
        case noBase
        case notJSON

        var reason: String {
            switch self {
            case .notAnObject: "the message is not an object"
            case let .unknownKind(kind):
                "`kind: \(kind ?? "none")` is not `\(CanvasDataWrite.kind)`"
            case .noBase:
                "a write names the text it replaces in `base` (null when there was no file)"
            case .notJSON: "`data` is not a JSON object or array"
            }
        }
    }

    /// From whatever WebKit handed over. Refuses rather than guesses, as every page channel does.
    static func decode(_ body: Any) -> Result<CanvasDataWrite, Refusal> {
        guard let payload = body as? [String: Any] else { return .failure(.notAnObject) }
        let kind = payload["kind"] as? String
        guard kind == Self.kind else { return .failure(.unknownKind(kind)) }
        let base: String?
        switch payload["base"] {
        case let text as String: base = text
        case is NSNull: base = nil
        default: return .failure(.noBase)
        }
        // `isValidJSONObject` first: `data(withJSONObject:)` traps rather than throwing on a value
        // it cannot write (NaN, a scalar at the top).
        guard let data = payload["data"], JSONSerialization.isValidJSONObject(data),
            let encoded = try? JSONSerialization.data(
                withJSONObject: data,
                options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        else { return .failure(.notJSON) }
        return .success(
            CanvasDataWrite(
                text: String(decoding: encoded, as: UTF8.self) + "\n", base: base,
                notify: payload["notify"] as? Bool ?? true))
    }
}

/// What the page is answered: the text now in the file, and whether it is the page's own.
enum CanvasDataAnswer: Equatable {
    /// Written. `text` is the file now, the page's next `base`.
    case written(String)
    /// Somebody else wrote it since the page read it, and nothing was written. `text` is what is
    /// there: apply your change to it and write again.
    case changed(String)

    var reply: [String: Any] {
        switch self {
        case let .written(text): ["kind": "written", "text": text]
        case let .changed(text): ["kind": "changed", "text": text]
        }
    }
}

// MARK: - The channel

/// Receives a page's writes to its live file, and nothing else.
///
/// **Its own object, as the annotation bridge is the coordinator's**, so there is no `switch` on
/// `message.name` for the operator's channel and the page's to be confused in. A reply handler
/// rather than a plain one, because the page has to learn whether its write landed and, when it
/// did not, what it is writing over.
///
/// **The origin check is the same one as the bridge's.** A cross-origin iframe reaches a page-world
/// handler, so a write is accepted only from this canvas's own main frame; without it one
/// artifact could write another's data.
@MainActor
final class CanvasDataChannel: NSObject, WKScriptMessageHandlerWithReply {
    typealias Write = (CanvasDataWrite) -> Result<CanvasDataAnswer, CanvasFileFailure>

    private let host: String
    private let onWrite: Write

    init(host: String, onWrite: @escaping Write) {
        self.host = host
        self.onWrite = onWrite
    }

    /// WebKit delivers script messages on the main thread, in order, which is what makes
    /// `assumeIsolated` right here: a page's second write is compared after its first landed.
    nonisolated func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let frame = message.frameInfo
            guard
                CanvasAddress.accepts(
                    isMainFrame: frame.isMainFrame,
                    originScheme: frame.securityOrigin.protocol,
                    originHost: frame.securityOrigin.host,
                    expectedHost: host)
            else { return replyHandler(nil, "only the canvas's own page writes its data") }
            // Every refusal rejects the page's promise with the reason, and is logged: the page's
            // author reads the first, and `log show` is where anybody else can.
            let answer = CanvasDataWrite.decode(message.body)
                .mapError { CanvasFileFailure(reason: $0.reason) }
                .flatMap(onWrite)
            switch answer {
            case let .success(answer): replyHandler(answer.reply, nil)
            case let .failure(failure):
                NSLog("helm: a canvas's live-file write was refused — \(failure.reason)")
                replyHandler(nil, failure.reason)
            }
        }
    }
}

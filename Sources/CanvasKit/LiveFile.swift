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
/// benchd writes only over those, or where the file is gone (`file/write`'s `unchanged`). A page that did not see the newest
/// version is answered `changed` with it, and replays its own change on top. That is the whole
/// concurrency story: nobody's write replaces a version its writer has not seen.
///
/// `kind` from the first message, on `AGENTS.md`'s rule, so a second kind is an addition.
package struct CanvasDataWrite: Equatable {
    /// The handler an `.html` artifact posts to:
    /// `window.webkit.messageHandlers.helmCanvasData.postMessage(…)`, which answers with a
    /// promise. Page world, and deliberately not the annotation bridge's name or world: a page
    /// can write its own data, and still cannot forge the operator's mark (#164).
    ///
    /// A page may write with nobody clicking, on load or on a timer, and a `notify` write mails
    /// the canvas's opener. That is the agent's own artifact waking the agent, which is why the
    /// mail says the *page* changed the file (`benchd/src/live.rs`) and not that he did.
    package static let handlerName = "helmCanvasData"
    package static let kind = "canvas.data.write"

    /// The JSON helm writes: keys sorted, pretty, a trailing newline. The same data always
    /// writes the same bytes, so a page that writes what is already there changes nothing.
    package let text: String
    /// What the page saw of the file: nil when there was none.
    package let base: String?
    /// Whether the agent that opened the canvas is mailed about it. A page reporting its own
    /// state says `false`, so nobody is woken for it.
    package let notify: Bool

    package init(text: String, base: String?, notify: Bool) {
        self.text = text
        self.base = base
        self.notify = notify
    }

    package enum Refusal: Error, Equatable {
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
    package static func decode(_ body: Any) -> Result<CanvasDataWrite, Refusal> {
        guard let payload = body as? [String: Any] else { return .failure(.notAnObject) }
        let kind = payload["kind"] as? String
        guard kind == Self.kind else { return .failure(.unknownKind(kind)) }
        let base: String?
        switch payload["base"] {
        case let text as String: base = text
        case is NSNull: base = nil
        default: return .failure(.noBase)
        }
        guard let data = payload["data"], let text = text(of: data) else {
            return .failure(.notJSON)
        }
        return .success(
            CanvasDataWrite(text: text, base: base, notify: payload["notify"] as? Bool ?? true))
    }

    /// A live file's JSON as every writer writes it, a page or Pocket: keys sorted, pretty, a
    /// trailing newline. nil for a value JSON cannot hold (NaN, a scalar at the top), checked
    /// first because `data(withJSONObject:)` traps rather than throwing on one.
    package static func text(of value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
            let encoded = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: encoded, as: UTF8.self) + "\n"
    }
}

extension CanvasFiles {
    /// A page's write of its live file at `path`, as helm's canvas and Pocket's page both carry
    /// it: written over exactly the page's `base` (none: over nothing), and answered with what is
    /// in the file now. A file that changed since is handed back byte for byte
    /// (`CanvasText.decode`, a byte-order mark kept), so it is the page's next base; one that is
    /// not UTF-8 text cannot be a base at all and is refused by name, never handed back with its
    /// bytes replaced, which would conflict with every later write.
    package func writeLive(
        _ write: CanvasDataWrite, to path: String
    )
        -> Result<CanvasDataAnswer, CanvasFileFailure>
    {
        switch self.write(
            write.text, to: path, expect: .unchanged(write.base ?? ""), notify: write.notify)
        {
        case .written: return .success(.written(write.text))
        case let .changed(now):
            guard let text = CanvasText.decode(now) else {
                let name = (path as NSString).lastPathComponent
                return .failure(CanvasFileFailure(reason: "\(name) changed, and is not UTF-8 text"))
            }
            return .success(.changed(text))
        case let .failed(why): return .failure(CanvasFileFailure(reason: why))
        }
    }
}

/// What the page is answered: the text now in the file, and whether it is the page's own.
package enum CanvasDataAnswer: Equatable {
    /// Written. `text` is the file now, the page's next `base`.
    case written(String)
    /// Somebody else wrote it since the page read it, and nothing was written. `text` is what is
    /// there: apply your change to it and write again.
    case changed(String)

    package var reply: [String: Any] {
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
package final class CanvasDataChannel: NSObject, WKScriptMessageHandlerWithReply {
    package typealias Write = (CanvasDataWrite) -> Result<CanvasDataAnswer, CanvasFileFailure>

    private let host: String
    private let onWrite: Write

    package init(host: String, onWrite: @escaping Write) {
        self.host = host
        self.onWrite = onWrite
    }

    /// WebKit delivers script messages on the main thread, in order, which is what makes
    /// `assumeIsolated` right here: a page's second write is compared after its first landed.
    package nonisolated func userContentController(
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

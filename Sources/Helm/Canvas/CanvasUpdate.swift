import Foundation

/// **The artifact changed — offered to the live page before anything reloads it** (#109).
///
/// helm's only delivery used to be a document load: `CanvasModel.refresh()` bumps `generation`,
/// which changes `CanvasReloadKey`, which navigates the webview. That is correct for a document
/// and destroys everything for a *page* — scroll, focus, form input, a half-played game — and it
/// happens on **every** agent write, which is the ordinary way a canvas updates. The research
/// pass ranks the three deliveries (`~/.prp/helm-3ec376fc/research/canvas-agent-manipulation.md`):
/// full reload worst, targeted edit + hot reload better, *push data into the live page* best.
/// This is the third, on MCP Apps' shape — the host offers, the page applies, the document is
/// never reloaded.
///
/// **The contract is one sentence: a page that defines `window.helmCanvasUpdate` is never
/// reloaded by helm.** Not "is reloaded less often" — never. Defining the function is the page
/// saying *I hold state; tell me instead of replacing me*, and there is no second condition to
/// remember. What it does with the offer is its own business:
///
/// ```js
/// window.helmCanvasUpdate = function (update) {
///   // update.kind === "canvas.update", update.version, update.artifact, update.generation
///   refetchState();            // ./state.json, whatever the agent rewrote
///   return true;               // handled
///   // return false;           // "not now" — helm shows the operator "Updated — reload"
/// };
/// ```
///
/// **`kind` from the first message, not once there is a second** — the rule `AGENTS.md` states
/// and #216 is the bill for. The page→helm bridge shipped `{id, text, rect}` with no
/// discriminator, a second kind arrived in #112, and the gate that had to *infer* the shape
/// silently dropped every geometry mark for months. This channel carries one from the first
/// message, both ways: the offer says `kind: "canvas.update"` and the answer says
/// `kind: "canvas.update-answer"`, and `CanvasUpdateAnswer.decode` refuses an envelope or an
/// answer it does not recognise rather than guessing at it.
///
/// **Why this is not a message over the annotation bridge, which is the obvious place for it.**
/// The bridge lives in a named content world (`CanvasFileCoordinator.bridgeWorld`, #164)
/// precisely so an artifact's own JavaScript cannot post to helm — and `window.helmCanvasUpdate`
/// is the artifact's own JavaScript, in the page world, where `window.webkit.messageHandlers` is
/// not visible at all. The two worlds share a DOM and nothing else, so helm's injected script
/// cannot call the page's function either. Swift is the only thing that can reach both, so Swift
/// asks: `evaluateJavaScript(in: .page)` runs the wrapper below and its return value **is** the
/// answer. Nothing new is exposed to the page, which a second message handler registered in the
/// page world would be — and that is #110's decision to make, not this slice's.
struct CanvasUpdate: Equatable, Codable {
    /// This channel's discriminator, in the payload the page receives.
    static let messageKind = "canvas.update"

    /// Bumped when a field the page reads changes meaning. A page written against a later helm
    /// can refuse an older one, and vice versa, because the number is in the payload from the
    /// first message rather than added when it first mattered.
    static let currentVersion = 1

    /// The name the page defines to take the offer. A plain, greppable global rather than one of
    /// helm's `__helm`-prefixed internals: those live in the bridge world and are helm's own, and
    /// this one is written by whoever authored the artifact.
    static let handlerGlobal = "helmCanvasUpdate"

    var kind: String = CanvasUpdate.messageKind
    var version: Int = CanvasUpdate.currentVersion

    /// The artifact's file name — not its path. The page is already served from that directory
    /// and fetches siblings by relative URL, so the path buys it nothing and would put the
    /// operator's home directory into a page's `console.log`.
    var artifact: String

    /// Which update this is. The same counter `CanvasReloadKey` navigates on, so a page can tell
    /// two offers apart and a test can say which one it answered.
    var generation: Int

    init(artifact: URL, generation: Int) {
        self.artifact = artifact.lastPathComponent
        self.generation = generation
    }

    /// The wrapper helm evaluates in the **page** content world. Returns the answer envelope
    /// directly — there is no bridge in that world to post it over.
    ///
    /// Everything the page can do wrong is caught here rather than left to become an
    /// `evaluateJavaScript` error with no verdict in it: a handler that throws is a `failed`
    /// answer naming the throw, which the operator sees, and *not* a silent reload of the page
    /// that threw.
    ///
    /// The payload crosses as a JSON **string** parsed in the page rather than as an object
    /// literal spliced into the source. `CanvasHTML.jsString` is the same escaping the markdown
    /// source already goes through, and it means no field of this struct can ever end a string
    /// or a script tag, whatever an artifact's filename contains.
    func offerScript() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
            (function () {
              var answer = function (verdict, detail) {
                var out = { kind: "\(CanvasUpdateAnswer.messageKind)", answer: verdict };
                if (detail) { out.detail = String(detail).slice(0, 400); }
                return out;
              };
              var handler = window.\(CanvasUpdate.handlerGlobal);
              if (typeof handler !== "function") { return answer("unhandled"); }
              try {
                return answer(handler(JSON.parse(\(CanvasHTML.jsString(json)))) === false
                  ? "declined" : "applied");
              } catch (e) {
                return answer("failed", (e && e.message) ? e.message : e);
              }
            })()
            """
    }
}

/// What the page said about an offered update, and therefore what helm does next.
///
/// Five cases and five different actions, because collapsing any two of them loses the fact the
/// operator needs. In particular **`unhandled` and `unreadable` are not the same**: the first is
/// a page that never defined a handler, so reloading it is exactly today's behaviour and costs
/// nothing; the second is helm failing to get an answer at all, where it has no evidence either
/// way. Both reload, and they are still separate — one is the ordinary path and one is worth a
/// line in the log.
enum CanvasUpdateAnswer: Equatable {
    /// A handler ran and did not decline. The document is **not** reloaded.
    case applied
    /// A handler ran and returned `false`: *not now*. The operator gets the notice and the
    /// choice; helm does not take the page away from them.
    case declined
    /// A handler ran and threw. Also the notice — a page whose update handler is broken is
    /// still a page holding state, and reloading it to tidy up would destroy exactly what the
    /// handler existed to protect.
    case failed(String)
    /// No `window.helmCanvasUpdate`. Reload, exactly as helm always has.
    case unhandled
    /// helm could not read an answer: the evaluation errored, or came back as something this
    /// build does not recognise. Reload — with no handler in evidence there is no state claimed
    /// to protect, and reloading is the behaviour that predates this whole channel.
    case unreadable(String)

    static let messageKind = "canvas.update-answer"

    /// Whether helm may take the document away and load it again.
    ///
    /// **The one line the whole feature reduces to**, named here rather than spelled as a
    /// `switch` at the call site so that "a page with a handler is never reloaded" is a fact
    /// with one definition instead of a rule two call sites remember.
    var reloads: Bool {
        switch self {
        case .unhandled, .unreadable: true
        case .applied, .declined, .failed: false
        }
    }

    /// What to put in the notice strip, or nil when there is nothing to say — the page took the
    /// update, or helm is about to reload and the reload is the message.
    var notice: String? {
        switch self {
        case .declined: "Updated — the page is holding its state. Reload to see the new version."
        case let .failed(detail): "Updated — the page could not apply it (\(detail)). Reload?"
        case .applied, .unhandled, .unreadable: nil
        }
    }

    /// From whatever `evaluateJavaScript` handed back.
    ///
    /// **Refuses rather than guesses**, on both fields. A body without this channel's `kind` is
    /// not this channel's answer — the wrapper always writes one, so its absence means the value
    /// came from somewhere else — and an `answer` string this build does not know is a drift
    /// between the wrapper above and this switch, which is a thing to report rather than to
    /// round down to the nearest case.
    static func decode(_ body: Any?) -> CanvasUpdateAnswer {
        guard let payload = body as? [String: Any] else {
            return .unreadable("the page returned no answer object")
        }
        guard payload["kind"] as? String == messageKind else {
            return .unreadable("the answer carries no `kind: \(messageKind)`")
        }
        let detail = payload["detail"] as? String
        switch payload["answer"] as? String {
        case "applied": return .applied
        case "declined": return .declined
        case "failed": return .failed(detail ?? "no reason given")
        case "unhandled": return .unhandled
        case let other: return .unreadable("answer: \(other ?? "none")")
        }
    }
}

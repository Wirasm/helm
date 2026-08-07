import Foundation

// MARK: - The page's own JSON

/// What a page said about itself, validated once and never interpreted after (#110).
///
/// **helm does not know what a score is.** The page reports `{score, lesson, lastMotion}` and
/// the agent that wrote the page is the only thing that understands those words — so the one
/// job here is to be sure the bytes are JSON an agent can parse, and then to carry them
/// verbatim. Anything more would be helm having an opinion about an artifact's own vocabulary,
/// which is precisely what it has none of.
///
/// **A newtype rather than a `String` of JSON, on `AGENTS.md`'s rule** — *"an invariant with a
/// comment explaining it wants a type carrying it"*. The invariant is *"this is a JSON object,
/// small enough to read"*, it is checked at exactly one edge (`CanvasPageState.decode`), and
/// every site downstream — the latch, the file, the model's dedupe — needs it to hold. With a
/// raw `String` each of those would be answered by reading upwards, which is the defect
/// `SpoolWork`'s header names and `id`'s is the standing bill for.
///
/// **A top-level object, never an array or a scalar.** MCP Apps' `structuredContent` is an
/// object for the same reason: an agent reading the latch should be able to say `state.score`
/// without first asking what shape it got, and a page that sends `42` gets a refusal naming
/// what it did rather than a latch nobody can address into.
struct CanvasStateBody: Equatable {
    /// Why a value is not a body. Carried rather than collapsed into `nil` so a drop can be
    /// logged in terms someone can act on — a page sending an array and a page sending a
    /// megabyte are different bugs with different fixes.
    enum Invalid: Error, Equatable {
        case notAnObject
        case notJSON
        case tooLarge(bytes: Int)

        var reason: String {
            switch self {
            case .notAnObject: "the reported state is not a JSON object"
            case .notJSON: "the reported state is not representable as JSON"
            case let .tooLarge(bytes):
                "the reported state is \(bytes) bytes, over the \(CanvasStateBody.maxBytes)-byte "
                    + "limit"
            }
        }
    }

    /// **A limit about the reader, not about the disk.** The latch exists to be read by an agent
    /// on its next turn, and every byte of it lands in that agent's context window — 64 KB is
    /// already some sixteen thousand tokens of machine state before the operator has said
    /// anything. A page with more than this to say wants a sibling file it names *in* its state,
    /// which costs the agent one `Read` it chose to make instead of a tax on every turn.
    static let maxBytes = 64_000

    /// Canonical JSON text: keys sorted, so two reports of the same state compare equal
    /// whatever order the page's own `JSON.stringify` happened to emit. That is what makes the
    /// dedupe in `CanvasModel.pageDidReportState` a statement about the state rather than about
    /// the page's serializer.
    let json: String

    /// From whatever WebKit handed over — an `NSDictionary` for an ordinary JS object.
    init(_ value: Any) throws {
        guard let object = value as? [String: Any] else { throw Invalid.notAnObject }
        // Catches what a JS object can hold and JSON cannot: NaN, Infinity, a value WebKit
        // bridged to something `JSONSerialization` refuses. Asked before encoding because
        // `data(withJSONObject:)` traps rather than throwing on an invalid top-level object.
        guard JSONSerialization.isValidJSONObject(object) else { throw Invalid.notJSON }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { throw Invalid.notJSON }
        guard data.count <= Self.maxBytes else { throw Invalid.tooLarge(bytes: data.count) }
        json = text
    }
}

// MARK: - What the page may say

/// **Everything an artifact's own JavaScript may say to helm, and it is exactly one thing**
/// (#110).
///
/// ## The shape, and why it is a handler rather than a poll
///
/// #164 put the annotation bridge in a named content world (`CanvasFileCoordinator.bridgeWorld`)
/// so that an artifact's own scripts cannot post to helm at all, and #109 kept that intact by
/// carrying its update offer over `evaluateJavaScript(in: .page)` — helm asking, never the page
/// telling. It left the question this slice has to answer: **may a page speak first?**
///
/// It may, on this channel and no other, because **the risk #164 names is forgery of the
/// operator's intent, not page speech as such.** An annotation is a claim about what the human
/// did — *they circled this and said that* — and a page able to manufacture one would put words
/// in their mouth. A state report is a claim about the page itself, where there is nothing to
/// forge: a page lying that its score is 9999 is a page lying about its own score, which is its
/// author's business and reaches only a file the agent reads as *what the page says about
/// itself*.
///
/// **So the two destinations are kept rigidly apart, structurally rather than by care.** A
/// different handler name, registered in `WKContentWorld.page` on a **different object**
/// (`CanvasStateChannel`) that holds no reference to the annotation path at all, decoded by this
/// type, and sunk into `CanvasStateLatch` — which cannot reach `CanvasNotes`, cannot reach
/// `CanvasAnnotation`, and cannot construct one. There is no `switch` on `message.name` anywhere
/// for the two to be confused in, because there is no shared receiver to switch inside.
///
/// **What the other shape would have cost.** helm could instead *pull* — evaluate a well-known
/// page-world global and latch whatever came back — widening nothing. But there is no event to
/// hang the pull on: a page's state changes when the **operator plays**, and helm gets no signal
/// for that, so a pull is a timer. A timer is a wakeup per canvas per interval forever for a fact
/// that may never be read, and — the part that actually decides it — the latch's whole purpose is
/// to be *current* when the agent next reads it, which a sample interval is exactly the staleness
/// of. It also widens the page's vocabulary by the same amount either way: a name the page
/// defines and helm knows. What it saves is one registration; what it costs is that the report
/// stops being an event.
///
/// ## What it is not
///
/// **It is not a way into a live prompt, and cannot become one.** Nothing here wakes a session,
/// starts a turn, or spends a credit — the sink is a file, and the agent reads it when it next
/// runs. Saying anything to an agent *now* is still `ChatModel.canSend`'s `status == .idle` plus
/// the operator pressing Post, and this channel touches neither.
struct CanvasPageState: Equatable {
    /// The handler an `.html` artifact posts to:
    /// `window.webkit.messageHandlers.helmCanvasState.postMessage(…)`.
    ///
    /// **Deliberately not `CanvasBridgePolicy.handlerName`, and deliberately not near it.** The
    /// annotation bridge answers to `helmCanvas` in a named world; this answers to
    /// `helmCanvasState` in the page world. Two names, two worlds, two receivers — the day they
    /// share any of the three is the day a page can forge an annotation.
    static let handlerName = "helmCanvasState"

    /// Every message this channel understands.
    ///
    /// **One case, and the discriminator ships with it** — `AGENTS.md`'s rule stated as a rule:
    /// *"a payload that can grow a second kind carries a discriminator from the first one"*. The
    /// canvas has already paid the other bill once: the page→helm bridge shipped `{id, text,
    /// rect}` with no `kind`, a second shape arrived in #112, and the gate that had to *infer*
    /// which was which dropped every geometry mark for months with every test on both sides
    /// green (#216). `decode` switches over this exhaustively, so a second kind is a compile
    /// error until somebody decides what it means.
    enum Kind: String, CaseIterable {
        /// The page reporting what it is doing. `state` carries the page's own object.
        case state = "canvas.state"
    }

    /// Why a message was not a report. Named rather than collapsed, for `CanvasPageSelection
    /// .Refusal`'s reason one file over: *"an unknown kind"* and *"a state helm cannot store"*
    /// are a version skew and a bug in the page, and telling them apart is the difference
    /// between #216 and a ticket somebody can act on.
    enum Refusal: Error, Equatable {
        case notAnObject
        case noKind
        case unknownKind(String)
        case noState
        case invalidState(CanvasStateBody.Invalid)

        var reason: String {
            switch self {
            case .notAnObject: "the body is not an object"
            case .noKind: "the message carries no `kind`"
            case let .unknownKind(kind):
                "`kind: \(kind)` is not a kind this helm understands"
            case .noState: "a `\(Kind.state.rawValue)` message carrying no `state`"
            case let .invalidState(invalid): invalid.reason
            }
        }
    }

    let body: CanvasStateBody

    /// **Refuses rather than guesses, on every field.** The same rule `CanvasPageSelection
    /// .decode` holds one seam over, and for the same reason: this is an untrusted body from a
    /// page, and rounding an unrecognised one down to the nearest thing helm does understand is
    /// how a channel starts lying quietly.
    static func decode(_ message: Any) -> Result<CanvasPageState, Refusal> {
        guard let payload = message as? [String: Any] else { return .failure(.notAnObject) }
        guard let raw = payload["kind"] as? String else { return .failure(.noKind) }
        guard let kind = Kind(rawValue: raw) else { return .failure(.unknownKind(raw)) }
        switch kind {
        case .state:
            guard let reported = payload["state"] else { return .failure(.noState) }
            do {
                return .success(CanvasPageState(body: try CanvasStateBody(reported)))
            } catch let invalid as CanvasStateBody.Invalid {
                return .failure(.invalidState(invalid))
            } catch {
                return .failure(.invalidState(.notJSON))
            }
        }
    }
}

// MARK: - The latch on disk

/// **The file an agent reads on its next turn** — beside the artifact, latest-wins, no interrupt
/// (#110).
///
/// `~/.prp/<key>/canvas/motions.html` → `~/.prp/<key>/canvas/motions.state.json`
///
/// ## Overwrite, and why that is the whole design
///
/// `CanvasNotes` is append-never-rewrite because it holds the **operator's** comments and losing
/// one would lose something a human wrote. This holds machine state, where the opposite is true:
/// the current score is the answer and every earlier score is noise an agent has to read past to
/// find it. MCP Apps' `ui/update-model-context` — the standard this is modelled on — says the
/// host *"replaces the previous context from that View"* and MAY dedupe, for exactly this
/// reason. So the two files sit beside each other with different suffixes, different write rules
/// and no code path between them, and a page can no more append to the operator's notes than the
/// operator can overwrite the page's state.
///
/// ## It says what it is, because it is read outside the process
///
/// `format`, `version` and `writtenAt`, on `BenchSnapshot`'s pattern and `AGENTS.md`'s rule —
/// *"anything read outside the process says so in its header"*. The reader is an agent in a
/// terminal with `cat` and `jq`, not Swift, so there is no far-side type to compile against and
/// the envelope is the only thing that can make a version skew loud instead of silently
/// misread.
///
/// **`writtenAt` is a change signal, not a heartbeat**, and that is what makes staleness
/// checkable — the question SWE-Touch (arXiv:2608.02499) measured coding agents losing 7.7
/// points on SWE-bench Verified for getting wrong. `CanvasModel.pageDidReportState` skips a
/// write whose state is unchanged, so this timestamp answers *"when did the page last do
/// something different"* rather than *"when did it last speak"*. `BenchSnapshot.sameContent`
/// holds the identical rule for the identical reason.
///
/// **Reporting state, never restore state.** Nothing reads this back into helm; deleting it
/// costs an agent one turn's context and nothing else.
struct CanvasStateLatch: Equatable {
    static let currentFormat = "helm.canvas-state"
    static let currentVersion = 1

    /// The artifact's file name — not its path, for `CanvasUpdate.artifact`'s reason: the latch
    /// already sits in the artifact's own directory, so the path buys a reader nothing and would
    /// put the operator's home directory into a file an agent may quote back.
    let artifact: String
    let body: CanvasStateBody
    let writtenAt: Date

    init(artifact: URL, body: CanvasStateBody, writtenAt: Date) {
        self.artifact = artifact.lastPathComponent
        self.body = body
        self.writtenAt = writtenAt
    }

    /// `motions.html` → `motions.state.json`, `plan.md` → `plan.state.json`. Beside the canvas,
    /// whatever directory that is — the same placement rule as `CanvasNotes.sidecarURL`, and
    /// deliberately a different suffix so the two can never resolve to one file.
    static func sidecarURL(for canvas: URL) -> URL {
        let name = canvas.deletingPathExtension().lastPathComponent
        return canvas.deletingLastPathComponent().appendingPathComponent("\(name).state.json")
    }

    /// The latch as its file.
    ///
    /// The page's own JSON is re-read and nested rather than spliced in as text: hand-assembling
    /// a JSON document around an opaque string is how a wire format acquires a quoting bug that
    /// only fires on the one artifact whose state contains a brace.
    func fileContents() throws -> Data {
        let state = try JSONSerialization.jsonObject(with: Data(body.json.utf8))
        let document: [String: Any] = [
            "format": Self.currentFormat,
            "version": Self.currentVersion,
            "writtenAt": ISO8601DateFormatter().string(from: writtenAt),
            "artifact": artifact,
            "state": state,
        ]
        return try JSONSerialization.data(
            withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
    }

    /// **Replace, never append**, and atomically — the reader is another process, so a
    /// half-written latch would be an agent parsing a truncated file rather than reading the
    /// previous state.
    ///
    /// Throws rather than swallowing: a canvas opened through Browse… can live somewhere not
    /// writable, and a latch nobody can write is a capability that silently is not there.
    @discardableResult
    static func write(
        _ body: CanvasStateBody, for canvas: URL, at timestamp: Date
    ) throws
        -> CanvasStateLatch
    {
        let latch = CanvasStateLatch(artifact: canvas, body: body, writtenAt: timestamp)
        try latch.fileContents().write(to: sidecarURL(for: canvas), options: [.atomic])
        return latch
    }
}

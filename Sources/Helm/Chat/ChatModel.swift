import Foundation

/// One thing the chat face draws: a turn of the conversation, in file order.
struct ChatEntry: Identifiable, Equatable {
    enum Voice: Equatable {
        /// The operator typed it.
        case operatorTurn
        /// The agent wrote it.
        case agent
    }

    /// Arrival ordinal. File order **is** render order, so the ordinal is the
    /// identity — not `uuid`, which `--resume` copies verbatim into a new
    /// session's file and is therefore only unique *within* one transcript.
    let id: Int
    let turn: Int
    let voice: Voice
    let text: String
}

/// What the chat face is looking at.
enum ChatSource: Equatable {
    case searching
    /// Nothing to read, and the reason — the toggle is always pressable, so this
    /// is what it lands on when there is no agent to read.
    case unavailable(String)
    case reading(AgentSession)
}

/// Tails one agent's transcript and keeps three things: the conversation, the
/// heartbeat, and whether it is safe to type.
///
/// **Polling, not watching.** A status change rewrites an existing file, which a
/// directory-level `DispatchSource` does not reliably see — the same reason
/// `BoardModel` polls. A quarter second is well inside the beat of a view whose
/// content lands in discrete lumps seconds apart.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var entries: [ChatEntry] = []
    @Published private(set) var source: ChatSource = .searching
    /// Ids that are a turn's last word. Rebuilt whenever the conversation or the
    /// working flag moves — the live turn earns one only once it is over.
    @Published private(set) var answers: Set<Int> = []
    /// Wall-clock arrival of each content block, trimmed to the ticker's window.
    /// **Blocks, never their content**: this is the texture of the work, and it
    /// is the only place a tool call appears anywhere in this view.
    @Published private(set) var beats: [Date] = []
    @Published private(set) var status: AgentStatus?
    @Published private(set) var workingSince: Date?
    /// How many credentials the mask has replaced across everything read from
    /// this transcript — not just the rendered window, which is why it can
    /// outrun what is visible. Surfaced rather than swallowed: a silent mask is
    /// its own lie.
    @Published private(set) var maskedCount = 0

    /// **The tape runs unless the agent is idle** — `waiting` counts as working
    /// here. Do **not** reuse `AgentStatus.isWorking` for this: that is the
    /// *board's* collapse, which folds `waiting` in with `idle` because the board
    /// asks "does this need you?". The tape asks a different question, and an
    /// agent blocked on a prompt is mid-turn — treating it as finished would
    /// promote a block that is not the turn's last word and claim the turn ended.
    var isWorking: Bool {
        guard let status else { return false }
        return status != .idle
    }

    /// **The composer's gate, and the whole reason a composer is safe at all.**
    ///
    /// Prose typed into a live permission prompt is silently destructive — #29
    /// measured `yes go ahead that is fine` having its `y` approve and run a
    /// network command, with no error and nothing to undo — and `waiting` is
    /// precisely that case. `idle` is a typed field published per-pid and
    /// seconds-fresh, so this guard fails *closed*, unlike every content-sniffing
    /// detector the spike tried.
    ///
    /// **Do not rewrite this as `status?.isWorking == false`.** That is
    /// `AgentStatus`'s own collapse, built for the board, and it answers `true`
    /// for `waiting` — it would open the box on exactly the case this exists to
    /// refuse. (`!isWorking` above happens to be equivalent for all four
    /// statuses and differs only on `nil`; the board's is the one that is
    /// actively wrong. `ChatComposerGateTests` fails on both.)
    var canSend: Bool { status == .idle }

    /// How much history the ticker shows. Against the measurements: consecutive
    /// records land a median 1.41 s apart and a turn opens with ~8.83 s of
    /// silence, so eleven seconds holds a normal burst and still visibly empties
    /// when the agent goes quiet.
    static let tickerWindow: TimeInterval = 11

    /// The rendered window. A 13 MB transcript is thousands of blocks and only
    /// the recent ones are being read.
    var window: ArraySlice<ChatEntry> { entries.suffix(120) }

    private let registryRoot: URL
    private let transcriptRoot: URL
    private var tail = TranscriptTail()
    private var url: URL?
    private var turn = 0
    private var nextID = 0
    /// False until the first drain finishes. The opening read is the whole file:
    /// every block in it arrived before we were watching, so none of it is a
    /// heartbeat and none of it should mark the tape.
    private var primed = false
    private var lastLookup = Date.distantPast
    private var lastRegistryRead = Date.distantPast

    init(
        registryRoot: URL = AgentRegistry.defaultRoot,
        transcriptRoot: URL = TranscriptLocator.defaultRoot
    ) {
        self.registryRoot = registryRoot
        self.transcriptRoot = transcriptRoot
    }

    // MARK: - Poll

    /// Polls until cancelled — driven from the view's `.task`, so SwiftUI owns
    /// its lifetime and cancels it when the face is swapped away.
    func run(pid: @escaping () -> pid_t?, every interval: Duration = .milliseconds(250)) async {
        while !Task.isCancelled {
            tick(foregroundPid: pid())
            try? await Task.sleep(for: interval)
        }
    }

    func tick(foregroundPid: pid_t?) {
        // Unconditional: an agent that exits mid-turn must not leave its last
        // beats frozen on the tape.
        if !beats.isEmpty {
            let cutoff = Date().addingTimeInterval(-Self.tickerWindow)
            beats.removeAll { $0 < cutoff }
        }

        guard let foregroundPid else {
            settle(.unavailable("This terminal has no process running in it."))
            return
        }

        if case .reading(let session) = source {
            // Two cadences on purpose. Draining is a `stat`, a `headBytes` read,
            // and — most ticks — nothing else, because a turn opens with a median
            // 8.83 s of no bytes, so it is cheap enough to run at the poll rate.
            // (The head read is #92's third guard, and it has to be asked on the
            // quiet ticks too: a rewrite through the same inode need not change
            // the length. `TranscriptTail.poll` argues it and carries the
            // measurement — do not restate the figure here, one of the two copies
            // would go stale and nothing would notice.) Re-reading the registry
            // is a directory listing plus a read and decode per row, and `status`
            // moves on transitions rather than continuously, so half-second
            // latency on it is invisible while four times the file traffic on the
            // main actor, under a live Metal view, is not.
            if Date().timeIntervalSince(lastRegistryRead) > 0.5 {
                lastRegistryRead = Date()
                let rows = AgentRegistry.sessions(in: registryRoot)
                if let fresh = rows.first(where: { $0.pid == session.pid }) {
                    if fresh != session { source = .reading(fresh) }
                    setStatus(fresh.status)
                } else if !AgentLocator.isAlive(session.pid) {
                    setStatus(nil)
                    settle(.unavailable("The agent that was running here has exited."))
                    return
                }
            }
            if let url { drain(url) }
            return
        }

        // Rediscovery is the expensive path (a directory listing plus a process
        // walk); once a second is far more often than an agent starts.
        guard Date().timeIntervalSince(lastLookup) > 1 else { return }
        lastLookup = Date()

        guard
            let session = AgentLocator.session(forForegroundPid: foregroundPid, root: registryRoot)
        else {
            settle(
                .unavailable(
                    "No Claude Code session is running in this terminal. "
                        + "Start one, or use the terminal face."))
            return
        }
        guard let found = TranscriptLocator.transcript(for: session, root: transcriptRoot) else {
            setStatus(session.status)
            settle(.unavailable("The agent has started but has not written anything yet."))
            return
        }
        reset()
        url = found
        source = .reading(session)
        setStatus(session.status)
        drain(found)
    }

    /// Publish an unavailable reason without churning: the poll runs four times a
    /// second and the same reason must not repost and redraw.
    private func settle(_ next: ChatSource) {
        if source != next { source = next }
        if url != nil { url = nil }
    }

    private func setStatus(_ next: AgentStatus?) {
        guard next != status else { return }
        let wasWorking = isWorking
        status = next
        if isWorking != wasWorking {
            workingSince = isWorking ? Date() : nil
            rebuildAnswers()
        }
    }

    private func reset() {
        entries = []
        answers = []
        beats = []
        tail = TranscriptTail()
        turn = 0
        nextID = 0
        primed = false
        maskedCount = 0
    }

    // MARK: - Drain

    private func drain(_ url: URL) {
        let batch = tail.poll(url)
        if batch.didReset {
            // The transcript was replaced, truncated, or rewritten where it
            // stood. Everything held is stale.
            entries = []
            answers = []
            turn = 0
            nextID = 0
            primed = false
            maskedCount = 0
        }
        guard !batch.lines.isEmpty else {
            primed = true
            return
        }

        let before = entries.count
        for line in batch.lines { ingest(line) }
        primed = true
        if entries.count != before { rebuildAnswers() }
    }

    private func ingest(_ line: Data) {
        guard let raw = try? JSONSerialization.jsonObject(with: line),
            let record = raw as? [String: Any]
        else { return }

        for meaning in TranscriptRecord.meanings(of: record) {
            switch meaning {
            case .ignored:
                continue
            case .agentActivity, .machineTurn:
                beat()
            case .operatorPrompt(let text):
                beat()
                turn += 1
                append(text, voice: .operatorTurn)
            case .agentProse(let text):
                beat()
                append(text, voice: .agent)
            }
        }
    }

    private func append(_ text: String, voice: ChatEntry.Voice) {
        let (masked, hits) = SecretMask.mask(text)
        if hits > 0 { maskedCount += hits }
        nextID += 1
        entries.append(ChatEntry(id: nextID, turn: turn, voice: voice, text: masked))
    }

    /// One content block landed. That is all the tape ever knows about it — no
    /// name, no kind, no content.
    private func beat() {
        guard primed else { return }
        beats.append(Date())
    }

    /// A turn's last word is the **last agent entry carrying that turn number**.
    /// Because entries are appended in file order and never sorted, that is
    /// exactly "the last `text` block of the last assistant record of the turn" —
    /// a position, not a pattern.
    ///
    /// The live turn is excluded while the agent is still working: until it
    /// stops, no block is its last word yet, and promoting one would be the view
    /// claiming an ending that has not happened.
    private func rebuildAnswers() {
        var lastOfTurn: [Int: Int] = [:]
        for entry in entries where entry.voice == .agent { lastOfTurn[entry.turn] = entry.id }
        if isWorking, let live = entries.last?.turn { lastOfTurn[live] = nil }
        answers = Set(lastOfTurn.values)
    }
}

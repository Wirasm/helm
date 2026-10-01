import AppKit
import Combine
import Foundation
import HelmWire
import SwiftUI
import os

/// helm's side of the bench: the ACTIVE workspace's bench as benchd last sent it, the door every
/// change goes out through, and the resolver from the bench's values to the objects they name.
///
/// **benchd owns the bench (#354); this draws it.** Every change helm makes — a key, a click, a
/// drag, a ⌘-clicked link — is a `BenchVerb` sent through `send`, which says who asked (an
/// agent's come to benchd through `bench`); benchd
/// applies its rules, and the document it made comes back on the follower and is drawn by
/// `apply`. Nothing here changes a bench itself, and `Workbench` has no method that could. With
/// benchd unreachable the last document stays on screen and a verb fails visibly
/// (`verbFailure`, and the status bar's capsule).
///
/// `TerminalManager` still owns every session, flat and app-wide, because a background
/// workspace's terminals must stay alive (`BoardModel.hostedPids` reads exactly that).
///
/// **Every command a vertical owns lives here, for the reason `TerminalWorkspace`'s header
/// gave and this makes truer.** That file kept the terminal commands inside the terminal
/// vertical so two features could be built without meeting in the same file. The
/// subscriptions did not stop being right — they moved up a level, because all of them are
/// *"act on the focused pane"* and focus is the bench's now. `AGENTS.md`'s rule is exact: a
/// subscription that has to work while its view is closed belongs on the model.
@MainActor
final class WorkbenchModel: ObservableObject {
    /// Nothing open, or a bench.
    @Published private(set) var mount: MountState = .empty

    /// nil when no workspace is open. Not an "empty bench": `Workbench`'s first invariant is that a bench always holds at least
    /// one pane, so there is no such value to make.
    ///
    /// Computed rather than stored: every reader outside this file reads what it always read,
    /// and `mount` is the one thing a writer can set.
    var bench: Workbench? { mount.bench }

    /// ⌘O's popover. App chrome rather than slot chrome — it appears once, on the focused
    /// slot's strip, because repeating it on every strip would multiply it by N. The
    /// *state* is here rather than in a view because the command that opens it is.
    @Published var isBrowserOpen = false

    /// ⌘J: the bench is drawn through `BenchCamera`, on the focused slot. helm's view and not
    /// the bench's, so it is here rather than in the document: no verb, no agent can set it, and
    /// a relaunch starts unzoomed. It names no slot: the camera follows focus, so there is no id
    /// to go stale when a pane closes. A look at one workspace's pane, so switching workspace
    /// turns it off (`apply`).
    @Published var isZoomed = false

    /// A pane's or a workspace's tab being dragged to another place (#178, `PaneDrop`,
    /// `WorkspaceDrop`). Its own object, observed only by the drop-zone overlay, so the pointer
    /// moving does not redraw the bench.
    let drag = BenchDrag()

    /// ⇧⌘O's sheet (`WorkspacePicker`): the command that opens it is here, so the state is too,
    /// as with `isBrowserOpen`.
    @Published var isWorkspacePickerOpen = false

    /// Why ⌘⇧N did not produce a note (#289) — no workspace open, or benchd could not start one.
    ///
    /// **Here rather than on a canvas, because the failure is that there is no canvas.** Every
    /// other thing helm says about a note is a strip inside its own pane; this one happens before
    /// a pane exists, so it has to be said on the bench. A keystroke that silently does nothing is
    /// a failure this project has paid for repeatedly, and this exists to stop it.
    ///
    /// Cleared by the next attempt that works, and by a timer — it is a receipt about a moment,
    /// not something to dismiss.
    @Published private(set) var noteFailure: String?
    private var noteFailureTask: Task<Void, Never>?

    private(set) var workspacePath: WorkspacePath?

    private let terminals: TerminalManager

    /// Every live pane object — sessions, canvases, browser views — keyed by pane id, one
    /// registry for every kind (`SurfaceKind`, PR 3a of #354). It is the terminal manager's, so
    /// the bench and the manager can never disagree about what is alive.
    private var surfaces: SurfaceRegistry { terminals.surfaces }

    /// How a mark leaves helm: as mail through benchd. Injected so the routing is reachable from
    /// `swift test` with a benchd the test answers for, and nothing sent to the operator's own.
    private let notes: CanvasNoteCourier

    /// benchd, over its socket: a request per verb, and the follower that delivers documents.
    let client: BenchClient

    /// The document the bench was last drawn from. nil until benchd first answers.
    @Published private(set) var document: BenchDocument?

    /// Why the last verb did not happen — a refusal, or benchd unreachable. Said for a while and
    /// then taken away, like a note's failure: it is about a moment.
    @Published private(set) var verbFailure: String?
    private var verbFailureTask: Task<Void, Never>?

    /// Handed each document once the bench is drawn from it, so whoever holds the workspace list
    /// (`RootView`) can follow the document's workspaces too. Set through `followDocuments`.
    private var documentFollower: ((BenchDocument) -> Void)?

    /// Follow every document from now on — starting with the one already drawn, if benchd
    /// answered before the caller was ready. The first document usually wins that race: the
    /// client connects when this model is made, and `RootView` wires its follower in `.task`.
    func followDocuments(_ follower: @escaping (BenchDocument) -> Void) {
        documentFollower = follower
        if let document { follower(document) }
    }

    /// `AnyCancellable`s rather than NotificationCenter tokens: they unsubscribe in their
    /// own deinit, and Swift 6 forbids a nonisolated deinit from touching the non-Sendable
    /// token the observer API hands back.
    private var commands: Set<AnyCancellable> = []

    /// Internal, not a `.shared`. `TerminalManager.shared` and `BoardModel.shared` are
    /// singletons because other slices reach them; nothing outside the workbench needs
    /// this one, and an injectable initialiser is what lets tests build isolated models.
    init(
        terminals: TerminalManager,
        notes: CanvasNoteCourier = CanvasNoteCourier(),
        makeBrowser: (@MainActor () -> BrowserPaneModel)? = nil,
        client: BenchClient
    ) {
        self.client = client
        self.terminals = terminals
        self.notes = notes
        // Registered here rather than by the manager because both need the bench: the canvas
        // kind the mark route, the browser kind a factory the caller chose. Re-registering
        // replaces, so a second model on one manager rewires them to itself.
        terminals.surfaces.register(
            CanvasPaneKind(files: BenchCanvasFiles(client: client)) { [weak self] model, pane in
                self?.wireMarks(model, in: pane)
            })
        terminals.surfaces.register(
            BrowserPaneKind(make: makeBrowser ?? { BrowserPaneModel(endpoint: client.endpoint) }))
        terminals.surfaces.register(UnsupportedPaneKind())
        terminals.surfaces.register(SessionsPaneKind(workbench: self, terminals: terminals))
        terminals.surfaces.register(ArchonPaneKind(workbench: self, terminals: terminals))
        terminals.surfaces.register(WorktreesPaneKind(workbench: self, terminals: terminals))
        // The same rewiring for the manager's sessions: a ⌘-clicked link is a verb, and this is
        // the bench it is sent to.
        terminals.bench = self
        subscribe()
        client.onDocument = { [weak self] at in self?.apply(at) }
        client.onChange = { [weak self] change in self?.remember(change) }
        // A `file/changed` sent while the follower was down, or before a benchd restart, reached
        // nobody: every open canvas reads its file again rather than show it stale.
        client.onConnected = { [weak self] in self?.rereadCanvases() }
        client.start()
    }

    // MARK: - What has each pane's terminal

    /// Ask benchd, every two seconds until cancelled, what has each terminal pane's terminal
    /// (`SessionForegrounds`): presence and the snapshot join Claude's registry on it. Driven from
    /// `WorkbenchView`'s `.task`, so its lifetime is the window's.
    ///
    /// Which agent a pane held is benchd's record now (M5b), written from the agents' own hooks;
    /// helm no longer writes it.
    func watchForegrounds(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await terminals.foregrounds.refresh(using: client)
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: - Resolving panes to the objects they name

    /// A pane's body and its tab, from its kind — the one route every kind is drawn by, so
    /// nothing in the bench's views asks what kind a pane is.
    func surfaceView(of pane: Pane, in slot: SurfaceSlot) -> AnyView? {
        surfaces.view(of: pane, in: slot, workspace: home(of: pane.id))
    }

    func surfaceTab(of pane: Pane, in slot: SurfaceSlot) -> AnyView? {
        surfaces.tab(of: pane, in: slot, workspace: home(of: pane.id))
    }

    /// What a surface needs to know about where it is drawn, answered by the bench.
    func surfaceSlot(for pane: Pane, in slot: Slot) -> SurfaceSlot {
        SurfaceSlot(
            pane: pane,
            holdsKeyboard: openDrawer == nil && bench?.focusedPane?.id == pane.id,
            isSelected: pane.id == slot.selected,
            canClose: bench?.canClose(pane.id) ?? false,
            select: { [weak self] in self?.send(.paneShow(pane.id), by: .operatorGesture) },
            close: { [weak self] in self?.send(.paneClose(pane.id), by: .operatorGesture) })
    }

    func session(for pane: Pane) -> TerminalSession? {
        surfaces.existing(pane.id, as: TerminalSession.self)
    }

    /// Resolve-or-create, at the edge. The model is kept by pane id so a tab switch or a
    /// re-render gets the same webview back rather than reloading the page.
    func canvas(for pane: Pane) -> CanvasModel {
        guard let model = surfaces.resolve(pane, in: home(of: pane.id)) as? CanvasModel else {
            preconditionFailure("canvas(for:) asked about a pane that is not a canvas: \(pane)")
        }
        return model
    }

    /// The return path (#205), wired onto every canvas model the canvas kind makes. AFTER
    /// construction, so resolving a restored pane into its own canvas is not mistaken for a
    /// mark. The identity check keeps an ORPHAN quiet: a model that is no longer the registry's
    /// for its pane has no origin to route to any more. `model` is captured weakly because the
    /// closure is stored on it.
    private func wireMarks(_ model: CanvasModel, in pane: Pane.ID) {
        model.onAnnotation = { [weak self, weak model] annotation, canvas in
            guard let self, let model, surfaces.existing(pane, as: CanvasModel.self) === model
            else {
                return .notSent(.noOrigin)
            }
            return deliver(annotation, on: canvas, markedIn: pane)
        }
        model.forkRoute = { [weak self] in
            self?.forkRoute(for: pane) ?? .unavailable(CanvasForkRoute.noOpener)
        }
        model.onAskFork = { [weak self, weak model] annotation, canvas, source in
            guard let self, let model, surfaces.existing(pane, as: CanvasModel.self) === model
            else {
                return .unavailable(CanvasForkRoute.noOpener)
            }
            return askFork(annotation, on: canvas, source: source, markedIn: pane)
        }
    }

    /// Whether a mark on canvas pane `pane` can be asked of a fork: benchd's record of the
    /// conversation that opened it (`Pane.author`, #535), read off the document.
    private func forkRoute(for pane: Pane.ID) -> CanvasForkRoute {
        let record = document?.pane(pane)
        return CanvasForkRoute.route(opener: record?.opener, author: record?.author)
    }

    /// Ask a read-only fork of the canvas's author about a mark (#535). benchd places the fork in
    /// the author's workspace and, because helm asks as `helm`, leaves the operator's focus alone.
    private func askFork(
        _ annotation: CanvasAnnotation, on canvas: URL, source: String?, markedIn pane: Pane.ID
    ) -> CanvasForkDelivery {
        let author: BenchDocument.Agent
        switch forkRoute(for: pane) {
        case let .unavailable(why): return .unavailable(why)
        case let .fork(agent): author = agent
        }
        guard case let .selection(anchor) = annotation.mark else {
            return .unavailable("This mark has no text to ask about")
        }
        let prompt = CanvasForkPrompt.text(
            canvas: canvas, source: source, marked: anchor.text, question: annotation.comment)
        let request = BenchForkRequest(
            id: "helm-\(UUID().uuidString.lowercased())", fork: author.session, cwd: author.cwd,
            prompt: prompt)
        do {
            let answer = try client.request(request, answering: BenchSpawned.self)
            guard answer.status == .ok, let spawned = answer.data else {
                return .failed(answer.reason ?? "benchd \(answer.status.rawValue)")
            }
            return .asked(handle: spawned.handle)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// An operator's mark on a canvas pane, on its way to the agent that opened that canvas
    /// (#205).
    ///
    /// **The opener is benchd's record** (`Pane.opener`, #532): benchd writes it at an agent's
    /// `pane/open`, and it is in the document, so it outlives a helm relaunch. What this does not
    /// do is *make* the decision — `CanvasNoteRoute.route` is pure and tested on its own, and
    /// this only supplies it with a live lookup.
    private func deliver(
        _ annotation: CanvasAnnotation, on canvas: URL, markedIn pane: Pane.ID
    ) -> CanvasNoteDelivery {
        let opener = document?.pane(pane)?.opener.map(CanvasOrigin.init(terminal:))
        let route = CanvasNoteRoute.route(origin: opener) { origin in
            // A closed pane resolves to no agent, which is `.originGone` — the agent that
            // opened this canvas is not there any more, and the operator is told so.
            document?.pane(origin.terminal) == nil ? nil : notes.handle(in: origin.terminal)
        }
        return notes.send(annotation, on: canvas, along: route)
    }

    func browser(for pane: Pane) -> BrowserPaneModel {
        guard let model = surfaces.resolve(pane, in: home(of: pane.id)) as? BrowserPaneModel
        else {
            preconditionFailure("browser(for:) asked about a pane that is not a browser: \(pane)")
        }
        return model
    }

    /// What ⌘+/⌘0/⌘↑ act on.
    var focusedTerminal: TerminalSession? {
        bench?.focusedPane.flatMap(session(for:))
    }

    // MARK: - Commands

    /// ⌘⇧N — start a note and put the operator in it (#289).
    ///
    /// **`open` rather than `offer`, and the cursor placed rather than left where it was.** Every
    /// other route to a canvas pane weighs *appear, don't seize* (#125) because nobody asked for
    /// what is arriving. This one is the operator pressing a key and expecting to type, so seizing
    /// is the correct behaviour and the whole feature — which is also, exactly, why no agent verb
    /// reaches it.
    ///
    /// **Three decisions live elsewhere and are only called from here**, which is what keeps this
    /// method a wiring: where the note goes and what it is called are benchd's (`prp/note`, prp's
    /// own resolver on the agents' machine, M5c), where the pane lands is benchd's too, and
    /// whether the file may be written into at all is `CanvasModel.write()`'s.
    ///
    /// - Parameter date: what day the filename says, on the operator's calendar. Injected so the
    ///   collision rule is testable without waiting for midnight.
    ///
    /// **Async because benchd may run git to key the store** (#390): the request goes off the main
    /// actor, bounded by `PrpStores.resolvingTimeout`, and a git that hangs is benchd's sentence. The
    /// window stays live meanwhile, so the operator can switch workspace before the answer; the
    /// note is then left unopened in its own project's `notes/` rather than opened on the wrong
    /// bench.
    @discardableResult
    func newNote(on date: Date = Date()) async -> Pane.ID? {
        // A bench is what a pane goes into, and a workspace is what names the store. Both are nil
        // together in practice; the message names the one the operator can act on.
        guard let path = workspacePath, bench != nil else {
            announceNoteFailure(OperatorNote.Failure.noWorkspace.sentence)
            return nil
        }
        let prp = PrpStores(client: client)
        let day = OperatorNote.day(date)
        let started = await Task.detached { prp.note(workspace: path.value, day: day) }.value
        guard workspacePath == path, bench != nil else { return nil }
        let note: String
        switch started {
        case let .failure(failure):
            announceNoteFailure(OperatorNote.Failure.couldNotStart(failure.reason).sentence)
            return nil
        case let .success(made):
            note = made
        }
        // Unreachable: benchd names a note `.md` and never a sidecar, which is exactly what
        // `EditableFile` recognises. Checked rather than assumed so that a later change to either
        // half is a sentence rather than a note that opens and then refuses a character.
        guard EditableFile(URL(fileURLWithPath: note)) != nil else {
            announceNoteFailure(OperatorNote.Failure.notARecognisableNote(note).sentence)
            return nil
        }
        guard let id = send(.paneOpen(surface: .canvas(path: note)), by: .operatorGesture),
            let pane = bench?.pane(id)
        else { return nil }
        noteFailure = nil
        noteFailureTask?.cancel()
        // Straight into the writing face: the operator asked for somewhere to write, and a
        // rendered view of an empty file is a blank pane with a button on it.
        canvas(for: pane).write()
        return id
    }

    /// Say why, and take it away again. The timer is `CanvasModel.announce`'s, for its reason:
    /// the message is a receipt about something that just happened, not a task.
    private func announceNoteFailure(_ sentence: String) {
        noteFailure = sentence
        noteFailureTask?.cancel()
        noteFailureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.noteFailure = nil
        }
    }

    /// benchd's follower said a canvas file or its sidecar changed (`file/changed`, M5c): every
    /// canvas hears it and decides whether the path is its own. A frame of any other kind is not
    /// this method's and is ignored.
    func fileChanged(_ line: Data) {
        guard
            let frame = try? JSONDecoder().decode(
                BenchEventFrame<BenchFileChanged>.self, from: line),
            frame.event.kind == BenchFileChanged.kind
        else { return }
        for canvas in surfaces.models(CanvasModel.self) {
            canvas.fileChanged(frame.event.data.path)
        }
    }

    /// Every open canvas reads its file and notes again (`BenchClient.onConnected`).
    func rereadCanvases() {
        for canvas in surfaces.models(CanvasModel.self) { canvas.reread() }
    }

    /// Write every open draft now (#289).
    ///
    /// The app being quit, after which a debounced save can no longer happen. A canvas leaving
    /// the document is closed through its kind, and its `close()` saves too.
    func flushNotes() {
        for canvas in surfaces.models(CanvasModel.self) { canvas.saveDraft() }
    }

    // MARK: - Visibility

    /// Push what a session cannot know for itself onto every session in the app: `isVisible`,
    /// and — since #313 — the pane's name.
    ///
    /// On **every** document, not just on select: a close, a split or a focus move can all
    /// change which panes are on screen. Sessions in background workspaces are invisible by
    /// definition, which is why this walks every session rather than only this workspace's.
    ///
    /// **The name is pushed here rather than handed to the tab view, and that is what makes
    /// there be one answer to "what is this pane called" (#313).** `TerminalSession.displayTitle`
    /// is spent by three readers — the tab, `TerminalNotifier`, and `BenchSnapshot.TerminalRecord`
    /// — so a name the *view* knew about would have left `snapshot.json` reporting the OSC title
    /// while the tab beside it read something else. It is the same shape as `isVisible` for the
    /// same reason: a fact that belongs to the bench, about a session that has no way to ask.
    ///
    /// **A background workspace's sessions keep the name they were last pushed** until it is
    /// on screen again.
    ///
    /// It does nothing else. An earlier draft of this plan had it keep one `hostView`
    /// attached at 1×1pt in case zero attached ghostty surfaces stalled every pty — that
    /// was measured and it does not: a backgrounded pty ran a delayed command to completion
    /// with every surface unmounted. Do not reintroduce it from reading
    /// `TerminalSession`'s header, which predicts the opposite and is wrong about this.
    private func reconcileSessions() {
        let visible = bench?.visiblePaneIDs ?? []
        let names = Dictionary(
            (bench?.panes ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for session in terminals.sessions {
            let mine = session.workspacePath == workspacePath
            session.isVisible = mine && visible.contains(session.id)
            if let name = names[session.id] { session.name = name }
        }
    }

    // MARK: - Subscriptions

    private func subscribe() {
        // **⌘Q is the ordinary way to leave, and it reached no flush point at all** (#289).
        // Every other exit a note has — Read, closing the pane, pointing the canvas elsewhere,
        // closing the last workspace — is one of helm's own code paths. Quitting is not: the
        // process goes away with the debounce still pending, and a note typed in one burst with
        // no 600ms gap in it has never been written even once, so what is lost is the *whole
        // note* rather than a bounded tail. That is not a corner — "jot it down, ⌘Q" is the
        // shape of the feature.
        //
        // **Synchronous, with no `receive(on:)`**, and that is the point: the run loop is about
        // to stop, so a hop to the main queue is a save that never runs. AppKit posts this on
        // the main thread already.
        //
        // What it still does not cover is `kill -9`, and nothing can. That is the honest
        // remainder of `CanvasModel.saveDebounce`'s cost.
        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flushNotes() }
            }
            .store(in: &commands)
    }
}

// MARK: - The door

extension WorkbenchModel {
    /// How long a caller waits for the frame its verb made before reading the bench anyway.
    static let frameWait: TimeInterval = 1

    /// Every change to the bench, from anyone: `verb` is sent to benchd as `by`, and `asked` is
    /// the caller saying the operator asked for it, which lets an agent's verb take the keyboard
    /// the way the operator's own gesture does. benchd's focus rule reads both.
    ///
    /// Returns the pane the verb created or brought forward, when it did one of those; nil when
    /// it did neither, or did not happen — and then `verbFailure` says why.
    ///
    /// **Blocking, and that is the point.** A verb is one round trip on a local socket — spike
    /// S1 measured the whole path, send to `@Published`, at p99 under 6 ms. Blocking keeps verbs
    /// in the order they were made, and it lets a caller read what its verb did before it
    /// returns: benchd hands the frame to its followers before it answers, so
    /// `document(atLeast:)` has it.
    @discardableResult
    func send(_ verb: BenchVerb, by actor: BenchActor, asked: Bool = false) -> Pane.ID? {
        let request = BenchRequest(
            id: "helm-\(UUID().uuidString.lowercased())", verb: verb, by: actor, asked: asked)
        let started = DispatchTime.now()
        let answer: BenchResponse<LayoutReport>
        do {
            answer = try client.request(request, answering: LayoutReport.self)
        } catch {
            verbFailed("\(verb.name): \(error)")
            return nil
        }
        // An `error` can still carry a report: applied and logged, but bench.json not written.
        // The change is real, so it is drawn; the failure is said.
        if let report = answer.data, report.changed {
            let drawn = client.document(atLeast: report.seq, within: Self.frameWait) != nil
            // The round trip the operator feels: verb out, benchd's answer, the document it made
            // drawn. `log stream --predicate 'category == "bench"'` reads it.
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            Self.log.info(
                "\(verb.name, privacy: .public) by \(actor.kind, privacy: .public): \(ms, format: .fixed(precision: 2), privacy: .public) ms, drawn \(drawn, privacy: .public)"
            )
        }
        guard answer.status == .ok, let report = answer.data else {
            verbFailed(
                "benchd \(answer.status.rawValue) \(verb.name): \(answer.reason ?? "no reason given")"
            )
            return nil
        }
        return report.paneCreated ?? report.pane
    }

    private static let log = Logger(subsystem: "com.wirasm.helm", category: "bench")

    /// An agent's `bench open` of a canvas (M3). Who opened it is benchd's record now
    /// (`Pane.opener`, #532); what is left here is the render.
    ///
    /// **A re-open re-reads the file (#261).** benchd answers the pane already showing it and
    /// leaves it where it is; its render is helm's, and benchd watches the canvas, its sidecar and
    /// its live file, so an agent that rewrote only a sibling (`app.js`) reported nothing at all.
    func remember(_ change: BenchChange) {
        guard change.verb == "pane/open", case .agent = change.by, let pane = change.pane,
            case .canvas = document?.surface(of: pane)
        else { return }
        surfaces.existing(pane, as: CanvasModel.self)?.refresh()
    }

    /// A ⌘-clicked http address (#376): the address becomes a new tab of the shared browser, in
    /// the background. helm opens the browser pane itself rather than as the operator's gesture,
    /// so it lands where the placement rules send it without taking the keyboard from the
    /// terminal clicked in: by default the browser drawer, which it badges (#356).
    func openLink(_ link: URL) {
        guard let id = send(.paneOpen(surface: .browser), by: .helm) else { return }
        browser(for: Pane(id: id, content: .browser)).open(link)
    }
}

// MARK: - Drawn from benchd (#354)

extension WorkbenchModel {

    /// Draw the bench from benchd's document. Every change reaches the screen
    /// this way — the operator's key and an agent's verb alike — and nothing else writes `mount`.
    ///
    /// **What helm keeps for itself is the live objects**, reconciled against the document:
    /// a pane in no workspace any more has its object closed through its kind, and the terminals
    /// of the workspace on screen get a session each. A background workspace's terminals get
    /// theirs when it is first shown: a terminal's pty starts only once it is drawn, so a session
    /// made earlier would hold nothing — and on the first document after the import it would
    /// start the shells #85's question is about to ask whether to restore.
    ///
    /// **#85's question stays helm's** (D4): a bench worth asking about is not drawn until the
    /// operator answers, and the answer goes back to benchd as a verb.
    ///
    /// **Re-entered, by design.** A verb sent from inside `documentFollower` (the import) waits
    /// for the document it made, and that calls this again before the outer call returns. Each
    /// call draws the document it was handed, and nothing after `documentFollower` reads local
    /// state, so the inner call's newer document is what stays drawn. Keep it that way.
    func apply(_ at: DocumentAt) {
        let document = at.document
        self.document = document

        let alive = document.paneIDs
        for entry in surfaces.entries where !alive.contains(entry.id) {
            surfaces.close(entry.id)
        }

        let drawing = BenchDrawing.of(document)
        // ⌘J's zoom was a look at the workspace being left; the next one is drawn whole.
        if drawing.workspace != workspacePath { isZoomed = false }
        workspacePath = drawing.workspace
        mount = drawing.mount
        if let active = drawing.workspace, let bench = drawing.mount.bench {
            terminals.adopt(
                terminals: bench.terminalPaneIDs, in: active,
                attaching: document.workspace(at: active)?.bench
                    .attachCommands(bench: client.benchExecutable) ?? [:])
        } else if drawing.workspace == nil {
            terminals.deactivate()
        }
        reconcileSessions()
        documentFollower?(document)
    }

    /// Say why a verb did not happen. A refusal is benchd's own sentence.
    func verbFailed(_ why: String) {
        NSLog("helm: %@", why)
        verbFailure = why
        verbFailureTask?.cancel()
        verbFailureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.verbFailure = nil
        }
    }
}

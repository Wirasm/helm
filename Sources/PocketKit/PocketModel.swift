import BenchKit
import CanvasKit
import Combine
import Foundation
import HelmWire

/// Pocket as benchd's client (#625): helm's follower for the workspaces, and one verb per
/// question for everything else, over TCP to a benchd on the operator's machine.
///
/// Sessions and screens change without the document changing, so the views poll them while they
/// are on screen: `sessions/all` every two seconds, a screen ten times a second, as
/// `bench watch screen` does. Each verb runs off the main actor; a socket blocks.
@MainActor
package final class PocketModel: ObservableObject {
    /// The workspaces on the bench, in the document's order.
    @Published package private(set) var workspaces: [String] = []
    /// Each workspace's sessions, as `sessions/all` last answered.
    @Published package private(set) var sessions: [String: [BenchSessionRow]] = [:]
    /// The follower's state, or why there is nothing to follow.
    @Published package private(set) var state: BenchClient.State = .disconnected("not connected")
    /// Why the last sessions poll failed for a workspace, until one succeeds for all of them.
    @Published package private(set) var failure: String?
    /// The plan and review pages in the workspaces' stores, a section per workspace
    /// (`loadPages`).
    @Published package private(set) var pages: [PocketPageSection] = []
    /// Each running chat's last message, by session id (`sessions/log`), for the chats list.
    @Published package private(set) var previews: [String: ChatPreview] = [:]
    /// When each preview was last asked for, and the row's `updatedAtMs` then (`refreshPreviews`).
    private var previewed: [String: (updatedAtMs: UInt64, at: Date)] = [:]
    /// The canvases on the bench an agent opened, standardized: a reply to one is mailed to it.
    @Published private var opened: Set<String> = []

    @Published package private(set) var storeLinks = StoreLinks()

    private var client: BenchClient?
    private var following: AnyCancellable?

    package init() {}

    /// Follow the benchd at `url`, `tcp://<host>:<port>`. Anything else is refused by name and
    /// nothing is followed.
    package func connect(_ url: String) {
        client?.stop()
        client = nil
        following = nil
        workspaces = []
        sessions = [:]
        previews = [:]
        previewed = [:]
        pages = []
        storeLinks = StoreLinks()
        opened = []
        guard let endpoint = BenchEndpoint.tcp(url.trimmingCharacters(in: .whitespaces)) else {
            state = .disconnected("\(url) is not tcp://<host>:<port>")
            return
        }
        let client = BenchClient(endpoint: endpoint)
        following = client.$state.sink { [weak self] in self?.state = $0 }
        client.onDocument = { [weak self] at in
            self?.workspaces = at.document.workspaces.map(\.path)
            self?.opened = Set(
                at.document.workspaces.flatMap(\.bench.panes).compactMap { pane in
                    guard case let .canvas(path) = pane.surface, pane.opener != nil else {
                        return nil
                    }
                    return StandardizedPath(path).value
                })
        }
        client.start()
        self.client = client
    }

    package var endpoint: BenchEndpoint? { client?.endpoint }

    /// Back in the foreground: connect the follower again now, rather than wait for a socket the
    /// sleep or a network change killed to be noticed dead. Its backoff covers the rest.
    package func resume() {
        client?.reconnect()
    }

    /// Whether an agent opened `page` on the bench, so a reply to it reaches that agent.
    package func isOpened(_ page: PocketPage) -> Bool {
        opened.contains(StandardizedPath(page.path).value)
    }

    /// The operator saw the session's last turn: `sessions/seen`, as when he focuses its pane on
    /// the Mac. nil once benchd took it.
    package func markSeen(harness: String, session: String) async -> Refusal? {
        guard let endpoint else { return Refusal(Self.notConnected) }
        let request = BenchSessionsRequest.seen(
            id: Self.id("seen"), harness: harness, session: session)
        if case let .failure(why) = await Self.ask(request, at: endpoint, BenchSessionSeen.self) {
            return why
        }
        return nil
    }

    /// A page's files through benchd, for `CanvasSchemeHandler` and the page's live file.
    package var files: (any CanvasFiles)? { client.map(BenchCanvasFiles.init(client:)) }

    /// `sessions/all` for every workspace, until the calling task is cancelled.
    package func watchSessions(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refreshSessions()
            try? await Task.sleep(for: interval)
        }
    }

    /// The chats' previews, on a loop of their own: a slow transcript never holds up the
    /// sessions poll, which says who is asking.
    package func watchPreviews(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refreshPreviews()
            try? await Task.sleep(for: interval)
        }
    }

    /// Every workspace's sessions, asked one by one. A workspace benchd does not answer for keeps
    /// the rows it had, and `failure` says why; the others still update.
    package func refreshSessions() async {
        guard let endpoint, let asked = client else { return }
        var answered: [String: [BenchSessionRow]] = [:]
        var refused: String?
        for workspace in workspaces {
            let request = BenchSessionsRequest.all(id: Self.id("sessions"), workspace: workspace)
            switch await Self.ask(request, at: endpoint, BenchSessionList.self) {
            case let .success(list): answered[workspace] = list.rows
            case let .failure(why):
                answered[workspace] = sessions[workspace]
                refused = refused ?? why.description
            }
        }
        // A poll that began before `connect` moved to another benchd answers for the old one.
        guard client === asked else { return }
        sessions = PocketHome.owners(answered, workspaces: workspaces)
        failure = refused
    }

    package func screen(_ target: String) async -> Result<BenchScreen, Refusal> {
        guard let endpoint else { return .failure(Refusal(Self.notConnected)) }
        return await Self.ask(
            BenchScreenRequest.get(id: Self.id("screen"), target: target), at: endpoint,
            BenchScreen.self)
    }

    /// Type `input` into the session `target` names: nil once benchd took it, else why not. The
    /// caller keeps the refusal beside what was typed; `failure` is the sessions poll's.
    package func send(_ input: BenchScreenInput, to target: String) async -> Refusal? {
        guard let endpoint else { return Refusal(Self.notConnected) }
        let request = BenchScreenRequest.send(id: Self.id("send"), target: target, input: input)
        if case let .failure(why) = await Self.ask(
            request, at: endpoint, BenchScreenSent.self, writes: true)
        {
            return why
        }
        return nil
    }

    /// The `.html` pages of every workspace's prp store (`prp/stores`, then `prp/artifacts`), a
    /// section per workspace. nil once listed, else why not; the last list stays.
    package func loadPages() async -> Refusal? {
        guard let endpoint, let asked = client else { return Refusal(Self.notConnected) }
        // Each store once, under the first workspace that has it.
        var stores: [(workspace: String, key: String, dir: String)] = []
        for workspace in workspaces {
            let request = BenchPrpRequest(id: Self.id("stores"), .stores(workspace: workspace))
            switch await Self.ask(request, at: endpoint, BenchPrpStores.self) {
            case let .success(answer):
                if let key = answer.workspace,
                    let store = answer.stores.first(where: { $0.key == key }),
                    !stores.contains(where: { $0.key == key })
                {
                    stores.append((workspace, key, store.dir))
                }
            case let .failure(why): return why
            }
        }
        var listings: [(workspace: String, store: String, files: [BenchPrpArtifact])] = []
        for (workspace, key, dir) in stores {
            let request = BenchPrpRequest(id: Self.id("artifacts"), .artifacts(store: key))
            switch await Self.ask(request, at: endpoint, BenchPrpArtifacts.self) {
            case let .success(artifacts): listings.append((workspace, dir, artifacts.files))
            case let .failure(why): return why
            }
        }
        guard client === asked else { return nil }
        pages = PocketPages.sections(listings)
        return nil
    }

    /// The link authority is this connection's benchd, including its home for ~/ paths.
    package func loadStoreLinks() async -> Refusal? {
        guard let endpoint, let asked = client else { return Refusal(Self.notConnected) }
        let stores = await Self.ask(
            BenchPrpRequest(id: Self.id("stores"), .stores(workspace: nil)), at: endpoint,
            BenchPrpStores.self)
        let home = await Self.ask(
            BenchPrpRequest(id: Self.id("home"), .resolvePath("~")), at: endpoint,
            BenchPathResolved.self)
        guard client === asked else { return nil }
        switch (stores, home) {
        case let (.success(stores), .success(home)):
            storeLinks = StoreLinks(stores: stores.stores, home: home.path)
            return nil
        case let (.failure(why), _), let (_, .failure(why)): return why
        }
    }

    /// Reply to `page`: an entry added to its live file, written over exactly what was read
    /// (`expect`) with `notify`, so benchd mails the agent that opened the page. A write that
    /// lost to another writer is replayed on what that writer left, once.
    package func reply(_ text: String, to page: PocketPage) async -> Refusal? {
        guard let endpoint else { return Refusal(Self.notConnected) }
        guard let live = BenchLiveFile.path(for: page.path) else {
            return Refusal("\(page.title) is not an HTML page")
        }
        let read = await Self.ask(
            BenchFileReadRequest(id: Self.id("read"), path: live), at: endpoint,
            BenchFileRead.self)
        var current: Data?
        switch read {
        case let .success(.bytes(data)): current = data
        case .success(.absent): current = nil
        case .success(.outside): return Refusal("benchd will not read \(live)")
        case let .failure(why): return why
        }
        for _ in 0..<2 {
            // The base is the file's bytes exactly (`CanvasText`), or there is none to write over.
            let base = current.map(CanvasText.decode) ?? ""
            guard let base, let next = PocketReply.adding(text, at: Date(), to: current) else {
                return Refusal(
                    "the page's live file is not a UTF-8 JSON object; the reply was not written")
            }
            let request = BenchFileWriteRequest(
                id: Self.id("write"), path: live, text: next, expect: .unchanged(base),
                notify: true)
            switch await Self.ask(request, at: endpoint, BenchFileWrite.self, writes: true) {
            case .success(.written): return nil
            case let .success(.changed(now)): current = now
            case let .failure(why): return why
            }
        }
        return Refusal("the page's live file kept changing; send the reply again")
    }

    /// Start an orchestrator: `agent` in `workspace`, its first message `prompt`. benchd records
    /// it as the operator's spawn and moves no focus on the Mac (`BenchSpawnRequest.start`).
    package func start(
        _ agent: String, in workspace: String, model: String?, effort: String?, prompt: String
    ) async -> Refusal? {
        guard let endpoint else { return Refusal(Self.notConnected) }
        let request = BenchSpawnRequest(
            id: Self.id("start"), agent: agent, cwd: workspace,
            conversation: .start(prompt: prompt, model: model, effort: effort))
        // An agent's first start can take seconds: benchd answers once its pane is up.
        if case let .failure(why) = await Self.ask(
            request, at: endpoint, BenchSpawned.self, timeout: 15, writes: true)
        {
            return why
        }
        return nil
    }

    /// A page of one session's transcript (`sessions/log`).
    package func log(
        _ session: String, page: BenchSessionLogRequest.Page, limit: Int = 50
    ) async
        -> Result<BenchSessionLog, Refusal>
    {
        guard let endpoint else { return .failure(Refusal(Self.notConnected)) }
        let request = BenchSessionLogRequest(
            id: Self.id("log"), session: session, page: page, limit: limit)
        return await Self.ask(request, at: endpoint, BenchSessionLog.self)
    }

    /// How long a preview stands before it is asked for again although its row did not change.
    /// `updatedAtMs` is not a change signal for every row: a codex or pi agent benchd spawned keeps
    /// its spawn time, so its replies are found this way.
    package static let previewStanding: TimeInterval = 10

    /// The last message of every running session whose row changed since it was last asked for,
    /// or that has not been asked for in `previewStanding`. A failed read leaves the old preview,
    /// and so does a page of tool lines only.
    package func refreshPreviews() async {
        let running = sessions.values.joined().filter {
            if case .running = $0.state { true } else { false }
        }
        guard let asked = client else { return }
        for row in running {
            if let last = previewed[row.id], last.updatedAtMs == row.updatedAtMs,
                Date().timeIntervalSince(last.at) < Self.previewStanding
            {
                continue
            }
            // A short page: the last message is near the end, behind a few tool lines at most.
            let page = await log(row.id, page: .last, limit: 20)
            // A reconnect to another benchd while this was asked answers for the old one.
            guard client === asked else { return }
            previewed[row.id] = (row.updatedAtMs, Date())
            if case let .success(log) = page, let preview = ChatPreview(log) {
                previews[row.id] = preview
            }
        }
    }

    private static let notConnected = "not connected to a benchd"

    private static func id(_ verb: String) -> String { "pocket-\(verb)-\(UUID().uuidString)" }

    /// One verb, off the main actor: the answer, or benchd's reason for refusing it. `writes` is a
    /// verb that changes something (a send, a write, a spawn): unanswered, it may have.
    private nonisolated static func ask<Payload: Decodable & Sendable>(
        _ request: some Encodable & Sendable, at endpoint: BenchEndpoint, _: Payload.Type,
        timeout: TimeInterval = BenchClient.requestTimeout, writes: Bool = false
    ) async -> Result<Payload, Refusal> {
        await Task.detached {
            do {
                let answer = try BenchClient.request(
                    request, at: endpoint, answering: Payload.self, timeout: timeout)
                guard answer.status == .ok, let data = answer.data else {
                    return .failure(Refusal(answer.reason ?? "benchd refused without a reason"))
                }
                return .success(data)
            } catch let unanswered as BenchUnanswered {
                // Only a verb that changes something may have done it unseen: an unanswered read
                // changed nothing, and its caller may simply try again.
                return .failure(Refusal(unanswered.description, maybeSent: writes))
            } catch {
                return .failure(Refusal("\(error)"))
            }
        }.value
    }
}

/// Why a verb got no answer Pocket can use, in benchd's words or the socket's.
package struct Refusal: Error, Equatable, CustomStringConvertible {
    package let reason: String
    /// benchd was sent the request whole and never answered (`BenchUnanswered`): it may have
    /// carried it out. A screen clears what was typed rather than invite it a second time.
    package let maybeSent: Bool

    init(_ reason: String, maybeSent: Bool = false) {
        self.reason = reason
        self.maybeSent = maybeSent
    }

    package var description: String {
        maybeSent ? "no answer, so it may have gone; look before sending again (\(reason))" : reason
    }
}

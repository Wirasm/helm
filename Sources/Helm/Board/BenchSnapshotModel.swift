import Combine
import Foundation
import HelmWire
import SwiftUI

/// Publishes the current bench as a small atomically replaced JSON document.
@MainActor
final class BenchSnapshotModel: ObservableObject {
    typealias Writer = (BenchSnapshot) -> Bool

    private let directory: BenchSnapshotDirectory
    private let mailboxRoot: URL
    /// Claude Code's session registry — how a pane's foreground pid becomes a session id, and
    /// the session id a mailbox (#247). Injectable for the reason `mailboxRoot` is: a test that
    /// reads the operator's live `~/.claude/sessions` measures the machine, not the rule.
    private let registryRoot: URL
    private let now: () -> Date
    private let writer: Writer
    private let foregroundPid: (TerminalSession) -> pid_t?
    private let refreshInterval: Duration

    private var changes: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var scheduled = false
    /// The last snapshot actually written, so an unchanged one can be skipped. See `publish`.
    private var published: BenchSnapshot?
    private var isStarted = false
    private weak var workspaces: WorkspaceModel?
    private weak var workbench: WorkbenchModel?
    private weak var terminals: TerminalManager?

    init(
        directory: BenchSnapshotDirectory = .resolve(),
        mailboxRoot: URL = MailboxDirectory.resolve(),
        registryRoot: URL = AgentRegistry.defaultRoot,
        refreshInterval: Duration = .seconds(2),
        now: @escaping () -> Date = Date.init,
        foregroundPid: @escaping (TerminalSession) -> pid_t? = { $0.hostView.foregroundPid },
        writer: Writer? = nil
    ) {
        self.directory = directory
        self.mailboxRoot = mailboxRoot
        self.registryRoot = registryRoot
        self.refreshInterval = refreshInterval
        self.now = now
        self.foregroundPid = foregroundPid
        self.writer = writer ?? directory.write
    }

    func start(
        workspaces: WorkspaceModel,
        workbench: WorkbenchModel,
        terminals: TerminalManager
    ) {
        guard !isStarted else { return }
        isStarted = true
        self.workspaces = workspaces
        self.workbench = workbench
        self.terminals = terminals

        do {
            try directory.prepare()
        } catch {
            NSLog(
                "helm: could not prepare bench snapshot directory at %@: %@",
                directory.root.path, String(describing: error))
        }
        publish()

        observe(workspaces.objectWillChange)
        observe(workbench.objectWillChange)
        observe(terminals.objectWillChange)
        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                self?.publish()
            }
        }
    }

    func stop() {
        isStarted = false
        scheduled = false
        changes.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        workspaces = nil
        workbench = nil
        terminals = nil
    }

    /// Immediate refresh for deterministic tests and callers that already observed an
    /// external mailbox transition. Normal app use is driven by model changes and polling.
    func refresh() {
        guard isStarted else { return }
        publish()
    }

    private func observe(_ publisher: ObservableObjectPublisher) {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.schedule() }
            }
            .store(in: &changes)
    }

    private func schedule() {
        guard isStarted, !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, isStarted else { return }
            scheduled = false
            publish()
        }
    }

    private func publish() {
        guard isStarted, let workspaces, let workbench, let terminals else { return }
        let snapshot = BenchSnapshot.project(
            writtenAt: now(),
            workspaces: workspaces,
            workbench: workbench,
            terminals: terminals,
            // Read once per publish and handed down as one value. Both halves are re-read every
            // time — an agent's mailbox and its registry row both appear while helm is running,
            // and this file is republished every two seconds precisely to notice that.
            addressBook: AddressBook(
                owners: MailboxDirectory.owners(in: mailboxRoot),
                sessionFor: AgentRegistry.sessionLookup(in: registryRoot)),
            foregroundPid: foregroundPid)

        // **An identical snapshot is not written, so `writtenAt` means what every reader assumes
        // it means.** The file is rebuilt on a timer as well as on change — deliberately, see the
        // comment above — so before this it advanced roughly every two seconds whether or not
        // anything had happened. `AGENTS.md` tells a reader to "check `writtenAt` before acting",
        // which is right for *is this stale* and quietly wrong for the question an agent actually
        // asks: **did my push land?** An agent diffing `writtenAt` to detect a reaction saw one
        // every time. Measured by a capability test doing exactly that, with a no-edit control
        // run: 21:21:57 → 21:22:01 → 21:22:05, nothing touched.
        //
        // Compared with the previous `writtenAt` substituted in, because that field is the one
        // guaranteed to differ and is not itself news. Everything else in the value is content.
        if let published, snapshot.sameContent(as: published) { return }
        guard writer(snapshot) else {
            NSLog("helm: could not publish bench snapshot at %@", directory.snapshot.path)
            return
        }
        published = snapshot
    }
}

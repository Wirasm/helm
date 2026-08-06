import Combine
import Foundation
import SwiftUI

/// Publishes the current bench as a small atomically replaced JSON document.
@MainActor
final class BenchSnapshotModel: ObservableObject {
    typealias Writer = (BenchSnapshot) -> Bool

    private let directory: BenchSnapshotDirectory
    private let mailboxRoot: URL
    private let now: () -> Date
    private let writer: Writer
    private let foregroundPid: (TerminalSession) -> pid_t?
    private let refreshInterval: Duration

    private var changes: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var scheduled = false
    private var isStarted = false
    private weak var workspaces: WorkspaceModel?
    private weak var workbench: WorkbenchModel?
    private weak var terminals: TerminalManager?

    init(
        directory: BenchSnapshotDirectory = .resolve(),
        mailboxRoot: URL = MailboxDirectory.resolve(),
        refreshInterval: Duration = .seconds(2),
        now: @escaping () -> Date = Date.init,
        foregroundPid: @escaping (TerminalSession) -> pid_t? = { $0.hostView.foregroundPid },
        writer: Writer? = nil
    ) {
        self.directory = directory
        self.mailboxRoot = mailboxRoot
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
            owners: MailboxDirectory.owners(in: mailboxRoot),
            foregroundPid: foregroundPid)
        guard writer(snapshot) else {
            NSLog("helm: could not publish bench snapshot at %@", directory.snapshot.path)
            return
        }
    }
}

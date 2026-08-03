import Foundation

/// One bench pane's live view of Archon: either a run's node fold, or every run with a status.
@MainActor
final class ArchonRunPaneModel: ObservableObject {
    /// What the pane is pointed at, and what it therefore shows. **One optional rather than
    /// two**: a `run` and a `runs` field would let both be set, or neither, and the pane would
    /// have to decide which to believe on every draw.
    enum Content: Equatable {
        case run(ArchonRun)
        case list([ArchonRun])
    }

    let reference: ArchonPaneRef
    @Published private(set) var content: Content?
    @Published private(set) var failure: String?
    @Published private(set) var isRefreshing = false

    private let client: any ArchonClient
    /// Which project to ask about. Stamped at construction by `WorkbenchModel`, exactly like
    /// the workspace a cached canvas remembers — the pane may outlive the selection, and every
    /// `archon` call needs a repo to resolve from.
    private let workspacePath: String?

    init(
        reference: ArchonPaneRef, workspacePath: String?,
        client: any ArchonClient = ArchonCLI()
    ) {
        self.reference = reference
        self.workspacePath = workspacePath
        self.client = client
    }

    func poll(every interval: Duration = ArchonPolling.interval) async {
        await ArchonPolling.loop(every: interval) { await refresh() }
    }

    func refresh() async {
        guard let workspacePath else {
            failure = ArchonRailModel.noWorkspace
            return
        }
        // Same drop-on-overlap rule as the rail's, and for the same reason: a call slower than
        // the tick must not accumulate a queue of identical questions.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            switch reference {
            case let .run(id, _):
                content = .run(try await client.run(id: id, in: workspacePath))
            case let .runs(status):
                // Filtered by the CLI rather than here: `workflow runs` returns the 20 most
                // recent rows, so filtering helm-side would show the completed runs that
                // happen to be in the latest 20 — three of them, under a rail line saying 97.
                content = .list(try await client.runs(in: workspacePath, status: status).runs)
            }
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
        }
    }
}

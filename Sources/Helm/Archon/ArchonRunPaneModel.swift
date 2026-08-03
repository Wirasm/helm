import Foundation

@MainActor
final class ArchonRunPaneModel: ObservableObject {
    let reference: ArchonRunRef
    @Published private(set) var run: ArchonRun?
    @Published private(set) var failure: String?
    @Published private(set) var isRefreshing = false

    private let client: any ArchonClient

    init(reference: ArchonRunRef, client: any ArchonClient = ArchonCLI()) {
        self.reference = reference
        self.client = client
    }

    func poll(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            run = try await client.run(id: reference.id)
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
        }
    }
}

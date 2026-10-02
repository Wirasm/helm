import BenchKit
import Foundation
import HelmWire

/// The `bench` a pane runs to show a session (`SessionAttach`), as an absolute path: the one
/// beside the benchd `client` follows, else an installed one (`BenchExecutable`). helm's alone:
/// it runs `bench --version` as a process, which BenchKit, shared with Pocket, must not.
///
/// Asked once per connection (`BenchClient.connections`), since a restarted benchd may be a new
/// build somewhere else. Only an answer benchd gave is kept: a failure to ask is asked again at
/// the next drawing.
///
/// A benchd reached over TCP names a path on its own machine, so helm runs its own `bench`
/// instead (M5c), which reaches benchd through the `BENCH_URL` the pane inherits from helm.
/// That one is another build, so its version is compared with benchd's first (`OtherBuild`),
/// and the verdict either way is kept for the connection. A `bench` that does not say its
/// version in time gives no verdict (`NoAnswer`), and is asked again at the next drawing.
@MainActor
final class AttachBench {
    private let client: BenchClient
    private var kept: (connection: Int, verdict: Result<String, BenchExecutable.Unusable>)?

    init(client: BenchClient) {
        self.client = client
    }

    var current: Result<String, BenchExecutable.Unusable> {
        if let kept, kept.connection == client.connections { return kept.verdict }
        let connection = client.connections
        let (verdict, keep) = ask()
        kept = keep ? (connection, verdict) : nil
        return verdict
    }

    /// The verdict, and whether it holds for the rest of the connection.
    private func ask() -> (Result<String, BenchExecutable.Unusable>, keep: Bool) {
        if case .tcp = client.endpoint {
            switch BenchExecutable.local() {
            case let .failure(missing): return (.failure(.notFound(missing)), false)
            case let .success(bench):
                guard let benchd = benchdVersion() else { return (.success(bench), false) }
                let ours: String?
                do { ours = try BenchExecutable.version(of: bench) } catch {
                    // No verdict, so none is kept: the next drawing asks again.
                    return (.failure(.noAnswer(error)), false)
                }
                let verdict: Result<String, BenchExecutable.Unusable> =
                    BenchExecutable.OtherBuild(bench: bench, ours: ours, benchd: benchd)
                    .map { .failure(.otherBuild($0)) } ?? .success(bench)
                return (verdict, true)
            }
        }
        var why: String?
        let reply: BenchResponse<BenchStatusReply>?
        do {
            reply = try client.request(
                BenchStatusRequest(id: "helm-status-\(UUID().uuidString)"),
                answering: BenchStatusReply.self)
        } catch {
            why = String(describing: error)
            reply = nil
        }
        let found = BenchExecutable.resolve(named: reply?.data?.bench, why: why)
        let result = found.mapError(BenchExecutable.Unusable.notFound)
        if case .success = result { return (result, true) }
        return (result, false)
    }

    /// benchd's `status.version`, or nil when benchd cannot be asked: the pane then attaches, and
    /// says for itself that it cannot reach benchd. A benchd that answers with no version
    /// predates the field, so it is another build: `unknown`.
    private func benchdVersion() -> String? {
        guard
            let reply = try? client.request(
                BenchStatusRequest(id: "helm-status-\(UUID().uuidString)"),
                answering: BenchStatusReply.self), reply.status == .ok
        else { return nil }
        return reply.data?.version ?? "unknown"
    }
}

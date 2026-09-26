import Foundation
import HelmWire

/// Where the bench comes from (#354). `local` is helm's own state, saved in its defaults — what
/// helm has always done. `daemon` is benchd's document: every verb is sent to benchd and the
/// bench is drawn from what its follower sends back.
///
/// **Opt in with `HELM_BENCH=daemon`.** PR 4 makes it the only mode once it has carried the
/// operator's own use; until then unsetting the variable is the way back.
enum BenchMode {
    case local
    case daemon(BenchClient)

    static let variable = "HELM_BENCH"

    @MainActor
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BenchMode {
        guard environment[variable] == "daemon" else { return .local }
        switch BenchClient.resolve(environment: environment) {
        case let .success(client):
            return .daemon(client)
        case let .failure(refused):
            // Refused rather than quietly local: a helm asked to render from benchd that renders
            // its own bench instead would look right and disagree with every agent's `bench`.
            return .daemon(BenchClient(unreachable: refused.sentence))
        }
    }

    var client: BenchClient? {
        if case let .daemon(client) = self { client } else { nil }
    }
}

/// The sink that sends every verb to benchd (#354). It changes nothing itself: the bench moves
/// when benchd's follower delivers the document the verb made.
///
/// **Blocking, and that is the point.** A verb is one round trip on a local socket — spike S1
/// measured the whole path, send to `@Published`, at p99 under 6 ms. Blocking keeps verbs in the
/// order they were made, and it lets a caller read what its verb did before it returns: benchd
/// hands the frame to its followers before it answers, so `document(atLeast:)` has it.
@MainActor
final class DaemonSink: VerbSink {
    private unowned let workbench: WorkbenchModel
    private let client: BenchClient

    /// How long a caller waits for the frame its verb made before reading the bench anyway.
    static let frameWait: TimeInterval = 1

    init(workbench: WorkbenchModel, client: BenchClient) {
        self.workbench = workbench
        self.client = client
    }

    @discardableResult
    func send(_ verb: BenchVerb, by actor: BenchActor, asked: Bool) -> Pane.ID? {
        // `bench/get` answers a document, not a report, and nothing needs it through the sink:
        // the follower already holds the document.
        if case .get = verb { return nil }
        let request = BenchRequest(
            id: "helm-\(UUID().uuidString.lowercased())", verb: verb, by: actor, asked: asked)
        let answer: BenchResponse<LayoutReport>
        do {
            answer = try client.request(request, answering: LayoutReport.self)
        } catch {
            workbench.verbFailed("\(verb.name): \(error)")
            return nil
        }
        // An `error` can still carry a report: applied and logged, but bench.json not written.
        // The change is real, so it is drawn; the failure is said.
        if let report = answer.data, report.changed {
            _ = client.document(atLeast: report.seq, within: Self.frameWait)
        }
        guard answer.status == .ok, let report = answer.data else {
            workbench.verbFailed(
                "benchd \(answer.status.rawValue) \(verb.name): \(answer.reason ?? "no reason given")"
            )
            return nil
        }
        return report.paneCreated ?? report.pane
    }
}

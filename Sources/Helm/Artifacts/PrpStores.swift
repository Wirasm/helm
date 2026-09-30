import Foundation
import HelmWire

/// helm's questions about prp's stores and about typed paths, asked of benchd (M5c, #459).
///
/// `~/.prp` lives on the agents' machine, which is benchd's, and a path the operator types names
/// a place there too, so helm reads neither itself — on one machine as much as across two, so the
/// path the operator uses daily is the one a remote bench uses. benchd answers with prp's own
/// resolver (`daemon/crates/benchd/src/prp.rs`); the wire is `bench_wire::prp`.
///
/// Blocking and bounded, like every verb helm sends: callable from the main actor, or from a
/// detached task for `note`, whose git run on benchd's side may take seconds.
struct PrpStores: Sendable {
    let client: BenchClient

    /// Why benchd did not answer: not reached, refused, or an answer this build cannot read. The
    /// reason is benchd's sentence where it gave one.
    struct Failure: Error, Equatable {
        let reason: String
    }

    /// How long a verb that resolves a workspace's store may take: `prp/note`, and `prp/stores`
    /// with a workspace. benchd gives the resolver `bench_wire::PRP_RESOLVE_WAIT` in all (3 s, the
    /// fixture's `resolve_wait_ms`), and `BenchPrpWireTests` holds this above it, so a slow git
    /// reaches helm as benchd's answer (a refusal, or the list without the workspace's store)
    /// rather than as helm's own timeout.
    static let resolvingTimeout: TimeInterval = 5

    /// Start a note in `workspace`'s store, named for `day` (`yyyy-MM-dd`). The new file's path.
    func note(workspace: String, day: String) -> Result<String, Failure> {
        ask(
            .note(workspace: workspace, day: day), BenchPrpNote.self, timeout: Self.resolvingTimeout
        )
        .map(\.path)
    }

    /// Every store, and `workspace`'s key when its store exists.
    func stores(workspace: String? = nil) -> Result<BenchPrpStores, Failure> {
        ask(
            .stores(workspace: workspace), BenchPrpStores.self,
            timeout: workspace == nil ? BenchClient.requestTimeout : Self.resolvingTimeout)
    }

    /// One store's renderable files, newest first.
    func artifacts(store: String) -> Result<[BenchPrpArtifact], Failure> {
        ask(.artifacts(store: store), BenchPrpArtifacts.self).map(\.files)
    }

    /// What the operator typed, as benchd's absolute path, when benchd says it is a `kind`. The
    /// one rule both typed-path fields keep (⇧⌘O wants a folder, the artifact browser a file), so
    /// each says the same thing about the wrong one.
    func resolve(_ typed: String, as kind: BenchPathResolved.Kind) -> Result<String, Failure> {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return .failure(Failure(reason: "Type a path first.")) }
        return ask(.resolvePath(typed), BenchPathResolved.self).flatMap { found in
            guard found.kind != kind else { return .success(found.path) }
            let said = kind == .directory ? "a file, not a folder" : "a folder, not a file"
            return .failure(Failure(reason: "\(found.path) is \(said)."))
        }
    }

    private func ask<Payload: Decodable & Sendable>(
        _ verb: BenchPrpRequest.Verb, _: Payload.Type,
        timeout: TimeInterval = BenchClient.requestTimeout
    ) -> Result<Payload, Failure> {
        let request = BenchPrpRequest(id: "helm-prp-\(UUID().uuidString)", verb)
        do {
            let answer = try client.request(request, answering: Payload.self, timeout: timeout)
            guard answer.status == .ok, let data = answer.data else {
                return .failure(Failure(reason: answer.reason ?? "benchd refused without a reason"))
            }
            return .success(data)
        } catch {
            return .failure(Failure(reason: String(describing: error)))
        }
    }
}

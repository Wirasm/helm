import BenchKit
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
    /// Why the last verb failed, until one succeeds.
    @Published package private(set) var failure: String?

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
        guard let endpoint = BenchEndpoint.tcp(url.trimmingCharacters(in: .whitespaces)) else {
            state = .disconnected("\(url) is not tcp://<host>:<port>")
            return
        }
        let client = BenchClient(endpoint: endpoint)
        following = client.$state.sink { [weak self] in self?.state = $0 }
        client.onDocument = { [weak self] at in
            self?.workspaces = at.document.workspaces.map(\.path)
        }
        client.start()
        self.client = client
    }

    package var endpoint: BenchEndpoint? { client?.endpoint }

    /// `sessions/all` for every workspace, until the calling task is cancelled.
    package func watchSessions(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refreshSessions()
            try? await Task.sleep(for: interval)
        }
    }

    package func refreshSessions() async {
        guard let endpoint else { return }
        var answered: [String: [BenchSessionRow]] = [:]
        for workspace in workspaces {
            let request = BenchSessionsRequest.all(id: Self.id("sessions"), workspace: workspace)
            switch await Self.ask(request, at: endpoint, BenchSessionList.self) {
            case let .success(list): answered[workspace] = list.rows
            case let .failure(why):
                failure = why.description
                return
            }
        }
        sessions = answered
        failure = nil
    }

    package func screen(_ target: String) async -> Result<BenchScreen, Refusal> {
        guard let endpoint else { return .failure(Refusal(Self.notConnected)) }
        return await Self.ask(
            BenchScreenRequest.get(id: Self.id("screen"), target: target), at: endpoint,
            BenchScreen.self)
    }

    /// Type `input` into the session `target` names. A failure is kept for the screen to say.
    package func send(_ input: BenchScreenInput, to target: String) async {
        guard let endpoint else { return failure = Self.notConnected }
        let request = BenchScreenRequest.send(id: Self.id("send"), target: target, input: input)
        switch await Self.ask(request, at: endpoint, BenchScreenSent.self) {
        case .success: failure = nil
        case let .failure(why): failure = why.description
        }
    }

    private static let notConnected = "not connected to a benchd"

    private static func id(_ verb: String) -> String { "pocket-\(verb)-\(UUID().uuidString)" }

    /// One verb, off the main actor: the answer, or benchd's reason for refusing it.
    private nonisolated static func ask<Payload: Decodable & Sendable>(
        _ request: some Encodable & Sendable, at endpoint: BenchEndpoint, _: Payload.Type
    ) async -> Result<Payload, Refusal> {
        await Task.detached {
            do {
                let answer = try BenchClient.request(
                    request, at: endpoint, answering: Payload.self)
                guard answer.status == .ok, let data = answer.data else {
                    return .failure(Refusal(answer.reason ?? "benchd refused without a reason"))
                }
                return .success(data)
            } catch {
                return .failure(Refusal("\(error)"))
            }
        }.value
    }
}

/// Why a verb got no answer Pocket can use, in benchd's words or the socket's.
package struct Refusal: Error, Equatable, CustomStringConvertible {
    package let description: String
    init(_ description: String) { self.description = description }
}

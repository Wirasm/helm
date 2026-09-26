import Foundation
import HelmWire

/// helm's mail, which is benchd's (#358): who is in a pane, and deliver a note to them. helm
/// keeps no mailroom; an agent in a pane has an address once its harness reports to benchd
/// through `bench hook`, and benchd answers for it.
///
/// Two closures rather than a protocol, so a test says what benchd would answer without a
/// daemon, and production talks to the one this helm's bench root names (`BenchRoot`).
struct BenchMailbox: Sendable {
    /// The mailbox of the agent in a pane, or nil when there is none or no benchd to ask.
    var who: @Sendable (_ pane: UUID) -> BenchMailWho?
    /// Deliver one message. Throws with benchd's reason, or why benchd could not be reached.
    var send:
        @Sendable (_ to: Handle, _ from: String, _ subject: String, _ body: String) throws -> Void

    /// benchd's reason, or why benchd could not be asked. `LocalizedError` so the operator's
    /// receipt carries the reason rather than Foundation's "error 1".
    struct Refused: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }

    /// benchd at this helm's bench root. With no root benchd would accept, nobody is reachable
    /// and every send says why.
    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BenchMailbox {
        switch BenchRoot.resolve(environment: environment) {
        case let .failure(why):
            return BenchMailbox(
                who: { _ in nil },
                send: { _, _, _, _ in throw Refused(description: String(describing: why)) })
        case let .success(root):
            let socket = root.appendingPathComponent("benchd.sock").path
            return BenchMailbox(
                who: { pane in
                    let answer = try? BenchClient.request(
                        BenchMailRequest.who(id: requestID(), pane: pane), at: socket,
                        answering: BenchMailWho.self)
                    return answer?.status == .ok ? answer?.data : nil
                },
                send: { to, from, subject, body in
                    let answer = try BenchClient.request(
                        BenchMailRequest.send(
                            id: requestID(), to: to, from: from, subject: subject, body: body),
                        at: socket, answering: BenchMailSent.self)
                    guard answer.status == .ok else {
                        throw Refused(
                            description: answer.reason ?? "benchd \(answer.status.rawValue)")
                    }
                })
        }
    }

    private static func requestID() -> String {
        "helm-\(UUID().uuidString.lowercased())"
    }
}

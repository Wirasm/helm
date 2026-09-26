import Foundation
import HelmWire

/// helm answering benchd (M3, #355): what only the window can do, asked by `bench get
/// screenshot` and carried to helm as a `helm/asked` event on the follow stream it already
/// reads. Each ask gets exactly one `helm/answer`, sent as helm, and benchd hands it to the agent
/// waiting on the socket.
///
/// The capture itself is the spool's (`SpoolCapturing`, `AppWindowCapturer`): drawing the window
/// into a PNG with no display grant. Only the trigger changed.
@MainActor
final class HelmAsks {
    private let capturer: any SpoolCapturing
    /// Where an answer goes. The client's own request, off the main actor, in the app.
    private let send: @Sendable (HelmAnswerRequest<CaptureReport>) -> Void

    init(
        capturer: any SpoolCapturing,
        send: @escaping @Sendable (HelmAnswerRequest<CaptureReport>) -> Void
    ) {
        self.capturer = capturer
        self.send = send
    }

    /// The live wiring: answers through `client`, off the main actor so a slow benchd never
    /// stalls a frame.
    static func answering(through client: BenchClient, capturer: any SpoolCapturing) -> HelmAsks {
        HelmAsks(capturer: capturer) { answer in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? client.request(answer, answering: EmptyReply.self)
            }
        }
    }

    /// A document-less frame off the follow stream (`BenchClient.onEvent`): answered when it is a
    /// `helm/asked`, ignored otherwise.
    func receive(_ line: Data) {
        guard let frame = try? JSONDecoder().decode(BenchEventFrame<HelmAsked>.self, from: line),
            frame.event.kind == "helm/asked"
        else { return }
        answer(frame.event.data)
    }

    func answer(_ asked: HelmAsked) {
        let id = "helm-answer-\(UUID().uuidString)"
        switch asked.request {
        case let .capture(path, window):
            switch capturer.capture(to: path, window: window) {
            case let .success(report):
                send(.init(id: id, ask: asked.ask, status: .ok, reason: nil, data: report))
            case let .failure(refusal):
                send(
                    .init(id: id, ask: asked.ask, status: .error, reason: refusal.reason, data: nil)
                )
            }
        case let .unknown(kind):
            send(
                .init(
                    id: id, ask: asked.ask, status: .refused,
                    reason: "this helm does not know how to answer a \(kind) ask", data: nil))
        }
    }
}

/// An answer whose data helm does not read.
struct EmptyReply: Decodable, Sendable {}

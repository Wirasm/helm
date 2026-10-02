import BenchKit
import Foundation
import HelmWire

/// helm answering benchd (M3, #355): what only the window can do, asked by `bench get
/// screenshot` and carried to helm as a `helm/asked` event on the follow stream it already
/// reads. Each ask gets exactly one `helm/answer`, sent as helm, and benchd hands it to the agent
/// waiting on the socket.
///
/// The capture itself is `AppWindowCapturer` (through `WindowCapturing`): drawing the window into
/// a PNG with no display grant, the screen locked or not. The answer carries the PNG and benchd
/// writes the file, so a helm on another machine answers an agent beside benchd (M5c).
@MainActor
final class HelmAsks {
    private let capturer: any WindowCapturing
    /// Where an answer goes. The client's own request, off the main actor, in the app.
    private let send: @Sendable (HelmAnswerRequest<CaptureReport>) -> Void

    init(
        capturer: any WindowCapturing,
        send: @escaping @Sendable (HelmAnswerRequest<CaptureReport>) -> Void
    ) {
        self.capturer = capturer
        self.send = send
    }

    /// The live wiring: answers through `client`, off the main actor so a slow benchd never
    /// stalls a frame. An answer that does not arrive leaves the agent told only that no helm
    /// answered, so helm logs why: a capture is several MB, and over a slow link to a remote
    /// benchd its upload can fail or outlast the ask (M5c).
    static func answering(through client: BenchClient, capturer: any WindowCapturing) -> HelmAsks {
        HelmAsks(capturer: capturer) { answer in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let reply = try client.request(answer, answering: EmptyReply.self)
                    if reply.status != .ok {
                        NSLog(
                            "helm: benchd did not take the answer to ask %@: %@", answer.ask,
                            reply.reason ?? "\(reply.status)")
                    }
                } catch {
                    NSLog("helm: could not answer ask %@: %@", answer.ask, "\(error)")
                }
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
        case let .capture(window):
            switch capturer.capture(window: window) {
            case let .success(report) where Self.answerBytes(report) > benchLargeRequestMaxBytes:
                let megabytes = report.png.count / (1024 * 1024)
                send(
                    .init(
                        id: id, ask: asked.ask, status: .error,
                        reason: "the capture is a \(megabytes) MB PNG, more than a helm/answer "
                            + "carries (\(benchLargeRequestMaxBytes / (1024 * 1024)) MB as base64)",
                        data: nil))
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

extension HelmAsks {
    /// The request line a capture answer makes: the PNG as base64, plus the report around it.
    static func answerBytes(_ report: CaptureReport) -> Int {
        (report.png.count + 2) / 3 * 4 + 4096
    }
}

/// An answer whose data helm does not read.
struct EmptyReply: Decodable, Sendable {}

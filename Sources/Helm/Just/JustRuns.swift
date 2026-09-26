import Foundation
import HelmWire
import SwiftUI

/// The just layer from helm's side (#356): a key bound to `just = "<recipe>"` asks benchd to run
/// that recipe from `<bench root>/rules/justfile` as the operator, and a run of his that fails
/// shows up on the status bar with its log one click away.
///
/// **benchd runs it, not helm**, so it is logged like every other change, dies with the daemon
/// rather than with the window, and an agent's `bench just` is the same verb. helm only sends
/// the verb and listens for `just/finished` on the follower; nothing here
/// executes a process.
///
/// **Only his own runs are tracked.** An agent's recipe failing is the agent's to report; the
/// bar shows what he pressed.
@MainActor
final class JustRuns: ObservableObject {
    /// Runs of his that ended in failure, newest last, until he looks at one or dismisses it.
    @Published private(set) var failures: [BenchJustFinished] = []
    /// Why the last run could not start, until the next one does.
    @Published private(set) var refusal: String?

    /// `just/run` as the operator. Blocking; called off the main actor.
    private let start: @Sendable (_ recipe: String) throws -> BenchJustStarted
    private var started: Set<String> = []
    /// Endings heard before the answer naming their run: a short recipe can finish before
    /// `run` has read benchd's answer. Kept briefly, then matched when the answer lands.
    private var early: [BenchJustFinished] = []

    init(start: @escaping @Sendable (String) throws -> BenchJustStarted = JustRuns.live()) {
        self.start = start
    }

    /// Ask benchd to run `recipe`. The answer does not wait for the run; `receive` hears how it
    /// ended.
    func run(_ recipe: String) {
        let start = self.start
        Task {
            let answer = await Task.detached { Result { try start(recipe) } }.value
            switch answer {
            case let .success(run):
                refusal = nil
                if let index = early.firstIndex(where: { $0.run == run.run }) {
                    record(early.remove(at: index))
                } else {
                    started.insert(run.run)
                }
            case let .failure(error):
                refusal = "just \(recipe): \(error)"
                NSLog("helm: just %@ did not start: %@", recipe, String(describing: error))
            }
        }
    }

    /// A frame with no document, as the follower read it. Only `just/finished` for a run helm
    /// started is kept, and only when it failed.
    func receive(_ line: Data) {
        guard
            let frame = try? JSONDecoder().decode(
                BenchEventFrame<BenchJustFinished>.self, from: line),
            frame.event.kind == "just/finished"
        else { return }
        let finished = frame.event.data
        guard started.remove(finished.run) != nil else {
            early = Array((early + [finished]).suffix(16))
            return
        }
        record(finished)
    }

    private func record(_ finished: BenchJustFinished) {
        if finished.failed { failures.append(finished) }
    }

    func dismiss(_ run: String) {
        failures.removeAll { $0.run == run }
    }

    func dismissRefusal() {
        refusal = nil
    }

    /// benchd at this helm's bench root.
    nonisolated static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> @Sendable (String) throws -> BenchJustStarted {
        let socket = BenchRoot.resolve(environment: environment)
            .map { $0.appendingPathComponent("benchd.sock").path }
        return { recipe in
            let path = try socket.mapError { Refused(description: $0.sentence) }.get()
            let answer = try BenchClient.request(
                BenchJustRequest(id: "helm-\(UUID().uuidString.lowercased())", recipe: recipe),
                at: path, answering: BenchJustStarted.self)
            guard answer.status == .ok, let started = answer.data else {
                throw Refused(description: answer.reason ?? "benchd \(answer.status.rawValue)")
            }
            return started
        }
    }

    struct Refused: Error, CustomStringConvertible {
        let description: String
    }
}

/// The status bar's word on the just layer: a run of his that failed, or one that could not
/// start. Clicking a failure opens its log as a canvas; the ✕ puts it away.
struct JustCapsules: View {
    @ObservedObject var runs: JustRuns
    let openLog: (String) -> Void

    var body: some View {
        if let refusal = runs.refusal {
            capsule(refusal, help: "The recipe did not start. Click to dismiss.") {
                runs.dismissRefusal()
            }
        }
        ForEach(runs.failures, id: \.run) { failure in
            capsule(
                "just \(failure.recipe) failed" + (failure.exit.map { " (\($0))" } ?? ""),
                help: "\(failure.log) — click to open the log"
            ) {
                openLog(failure.log)
                runs.dismiss(failure.run)
            }
        }
    }

    private func capsule(_ text: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280)
                .foregroundStyle(Color.surface)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.danger, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

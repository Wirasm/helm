import HelmWire
import SwiftUI

/// How many agents are waiting on the operator (M1, #357), and the way to the one waiting
/// longest: clicking does what ⌘⇧J does. Absent while nobody waits.
///
/// benchd decides who waits (`waiting` in its `sessions` answer): an agent's own report, or a
/// prompt benchd read off its screen. helm only counts, and sends `focus/waiting`.
struct WaitingCapsule: View {
    @ObservedObject var foregrounds: SessionForegrounds
    let workbench: WorkbenchModel

    var body: some View {
        if let summary = WaitingSummary(foregrounds.waiting.values) {
            Button {
                workbench.send(.focusWaiting, by: .operatorGesture)
            } label: {
                Text(summary.label)
                    .foregroundStyle(Color.surface)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.attention, in: Capsule())
            }
            .buttonStyle(.chrome)
            .help(summary.help)
        }
    }
}

/// What the capsule says, from benchd's waits. nil when there are none.
struct WaitingSummary: Equatable {
    let label: String
    let help: String

    init?(_ waits: some Collection<BenchLiveSessions.Waiting>) {
        guard let oldest = waits.min(by: { $0.since < $1.since }) else { return nil }
        label = "\(waits.count) waiting"
        help =
            "\(waits.count == 1 ? "An agent is" : "\(waits.count) agents are") waiting on you. "
            + "The longest: \(oldest.waitingFor), since "
            + oldest.since.formatted(date: .omitted, time: .shortened)
            + ". Click to go there; again for the next."
    }
}

import SwiftUI

/// The status bar's three counts (M1, #357): ● agents asking the operator, ✓ finished turns he has
/// not seen, ✉ mail to him. Only his own, and nothing at all while nobody needs him. A click
/// opens the Sessions drawer, whose "needs you" list names each one.
///
/// benchd decides what needs him (`Attention`); helm only counts.
struct AttentionCapsules: View {
    @ObservedObject var foregrounds: SessionForegrounds
    let workbench: WorkbenchModel

    var body: some View {
        let counts = Attention.counts(foregrounds.attention)
        ForEach(AttentionKind.allCases.filter { counts[$0, default: 0] > 0 }, id: \.self) { kind in
            Button {
                workbench.send(
                    .drawerToggle(name: "sessions", surface: .sessions), by: .operatorGesture)
            } label: {
                Text("\(kind.glyph) \(counts[kind, default: 0])")
                    .foregroundStyle(kind.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.surfaceRaised, in: Capsule())
            }
            .buttonStyle(.chrome)
            .help(kind.help(counts[kind, default: 0]))
        }
    }
}

extension AttentionKind {
    /// Its colour: amber for asking (helm's one waiting-on-you colour), teal for finished, quiet
    /// for mail.
    var color: Color {
        switch self {
        case .asking: .attention
        case .finished: .accent
        case .message: .textMuted
        }
    }

    func help(_ count: Int) -> String {
        let what =
            switch self {
            case .asking: "asking you"
            case .finished: "finished, not seen"
            case .message: "with mail for you"
            }
        return "\(count) \(count == 1 ? "agent" : "agents") \(what)"
    }
}

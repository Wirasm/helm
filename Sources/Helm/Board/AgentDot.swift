import SwiftUI

/// One workspace tab's mark (`WorkspaceMark`): the most urgent thing an agent there needs from
/// the operator, in the glyph every other surface uses (● asking, ✓ finished, ✉ mail), else a
/// quiet ○ while an agent there works, else nothing.
///
/// **It never hides**, including on the workspace you are looking at: selecting a workspace
/// shows you one of its terminals and says nothing about the others.
struct AgentDot: View {
    let mark: WorkspaceMark?

    var body: some View {
        switch mark {
        case .none:
            EmptyView()
        case .working:
            Text("○")
                .foregroundStyle(Color.textFaint)
                .help("An agent is working here")
                .accessibilityLabel("Agent working")
        case let .needs(kind):
            Text(kind.glyph)
                .foregroundStyle(kind.color)
                .help(kind.help(1) + " here")
                .accessibilityLabel(kind.help(1))
        }
    }
}

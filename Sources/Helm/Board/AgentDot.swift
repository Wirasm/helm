import SwiftUI

/// One workspace tab's agent mark.
///
/// Three renderings, not two: nothing where there is no agent, a quiet dot where
/// every agent is working, and the attention dot where one has stopped. Absence
/// stays distinct from *working* because the bar has to answer both halves of the
/// question — which workspaces have an agent, and are they fine. Collapse them and
/// a plain shell reads exactly like a live agent.
///
/// **It never hides**, including on the workspace you are looking at. Do not add an
/// `isSelected` gate; `TerminalStrip.swift`'s `indicator` explains at length why the
/// per-terminal rule does not carry up to a rollup, and the short version is that
/// selecting a workspace shows you one of its N terminals and says nothing about
/// the others.
///
/// Orange is helm's one attention colour — the same one the terminal bell uses. The
/// altitude differs, the meaning does not.
struct AgentDot: View {
    let presence: AgentPresence?

    var body: some View {
        switch presence {
        case .none:
            EmptyView()
        case .working:
            Circle()
                .fill(.tertiary)
                .frame(width: 5, height: 5)
                .help("An agent is working here")
                .accessibilityLabel("Agent working")
        case .notWorking:
            Circle()
                .fill(.orange)
                .frame(width: 5, height: 5)
                .help("An agent here has stopped — it is your turn")
                .accessibilityLabel("Agent needs you")
        }
    }
}

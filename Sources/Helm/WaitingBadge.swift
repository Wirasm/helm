import SwiftUI

/// "N waiting on you" — the count `docs/escalation.md` makes a hard requirement.
///
/// > Unanswered must be loud, and it must be countable. If helm cannot answer *"how many
/// > agents are blocked on me right now?"* at a glance, the mechanism is not finished.
/// > A list is not enough.
///
/// Dots on sidebar rows are a list. They tell you *where* attention is once you are already
/// looking at the sidebar — which is exactly the failure mode that doc names, and it cites
/// the 116 abandoned worktrees as precedent: a leak that stayed invisible until somebody
/// counted. So the count lives in the workspace bar, visible regardless of which kild is
/// selected or whether the sidebar is even in view.
struct WaitingBadge: View {
    let count: Int
    /// Scroll the column to the first waiting agent and open whatever fold it is inside.
    /// The count is the entry point; the list is the follow-through, which is the order the
    /// doc asks for.
    let reveal: () -> Void

    var body: some View {
        // Zero is ABSENCE, not "0". A zero permanently on screen becomes furniture, and
        // furniture is not loud — which would defeat the entire point of the badge.
        if count > 0 {
            Button(action: reveal) {
                Text("\(count) waiting on you")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Jump to the first agent waiting on you")
            .accessibilityLabel("\(count) agents waiting on you")
        }
    }
}

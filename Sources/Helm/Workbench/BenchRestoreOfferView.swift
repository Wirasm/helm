import Inject
import SwiftUI

/// The mount question, where the bench would be (#85).
///
/// **Rendering, and only rendering** — `WorkbenchView`'s rule, and this file is held to it
/// the same way. Which bench is offered, whether one is offered at all, and what each answer
/// does are `BenchMountPolicy`'s and `WorkbenchModel.answer`'s; the counts are readers on
/// `BenchRestoreOffer`. Nothing here decides anything.
///
/// **In the bench's own space rather than in a modal**, and that is the ticket's first
/// requirement: *"a startup modal is intrusive and wrong for multiple workspaces — it asks
/// about ones you are not opening yet."* Asked here, the question arrives with the workspace
/// bar above it saying which workspace it is about, and a workspace never visited costs
/// nothing.
///
/// It takes the shape `EmptyBench` already established for "this space has no panes in it" —
/// same glyph weight, same heading and detail rhythm, same button treatment — because they are
/// two answers to the same moment and reading as two different screens would be the defect
/// `Design/Palette.swift` exists to remove.
struct BenchRestoreOfferView: View {
    @ObserveInjection private var inject
    let offer: BenchRestoreOffer
    let answer: (BenchRestoreChoice) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 18) {
                glyph(size: 34)
                VStack(spacing: 6) {
                    heading
                    detail
                }
                buttons
            }
            HStack(spacing: 14) {
                glyph(size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    heading
                    detail
                }
                buttons
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface)
        .enableInjection()
    }

    private func glyph(size: CGFloat) -> some View {
        Image(systemName: "rectangle.3.group")
            .font(.system(size: size, weight: .light))
            .foregroundStyle(Color.textFaint)
    }

    /// **The pane count is the offer.** A bench that reopens silently grows without anyone
    /// noticing; naming the number is what makes bloat self-revealing, and it is why #85 calls
    /// this the most valuable part of the ticket.
    private var heading: some View {
        Text("Restore \(offer.paneCount) \(offer.paneCount == 1 ? "pane" : "panes")?")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
    }

    private var detail: some View {
        Text(BenchRestoreOfferView.detail(for: offer))
            .font(.system(size: 12))
            .foregroundStyle(Color.textMuted)
            .multilineTextAlignment(.center)
    }

    /// The breakdown under the count, as a string a test can read.
    ///
    /// It is `static` and pure for the reason the rest of this file defers to the model: it is
    /// the one piece of judgement on the surface — what is worth saying about a bench in one
    /// line — and a sentence trapped in a `body` is a sentence nothing can check.
    static func detail(for offer: BenchRestoreOffer) -> String {
        var parts: [String] = []
        if offer.terminalCount > 0 {
            parts.append("\(offer.terminalCount) terminal\(offer.terminalCount == 1 ? "" : "s")")
        }
        if offer.canvasCount > 0 {
            parts.append("\(offer.canvasCount) canvas\(offer.canvasCount == 1 ? "" : "es")")
        }
        var sentence =
            parts.isEmpty ? "This is what was here." : parts.joined(separator: ", ") + "."
        if offer.agentCount > 0 {
            // Named, because it is what declining costs: the agents can only be offered once
            // their panes exist, so fresh is also a decision not to be asked about them.
            sentence +=
                " \(offer.agentCount) had an agent running"
                + "\(offer.agentCount == 1 ? "" : " in it") — helm offers to resume "
                + "\(offer.agentCount == 1 ? "it" : "them") once the panes are back."
        }
        sentence += " Starting fresh gives one shell and keeps this arrangement."
        return sentence
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            button("Restore", emphasis: true) { answer(.restore) }
            button("Start Fresh", emphasis: false) { answer(.fresh) }
        }
    }

    private func button(
        _ title: String, emphasis: Bool, action: @escaping () -> Void
    )
        -> some View
    {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    emphasis ? Color.selection : Color.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(emphasis ? Color.accent : Color.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

import Inject
import SwiftUI

/// One restored terminal pane's resume offer, as a band above its shell (#63).
///
/// **It appears, it does not seize.** #33's rule — and the reason #63 says *offer, not push*
/// in its own words: *"an agent restarting itself unbidden after a crash is exactly the case
/// where it should not."* Resurrecting five agents that immediately start working is the
/// loudest seizure helm could perform, and an offer the operator accepts is the only form of
/// this that can be wrong safely. So nothing is claimed here: the band is chrome above a live
/// shell, the shell keeps the keyboard, and doing nothing at all leaves a plain terminal —
/// which is exactly what helm did before this existed.
///
/// **Rendering only**, as everything under `Workbench/` is: whether there is an offer, whether
/// it can be made good on, and what accepting runs are `WorkbenchModel`'s and
/// `AgentResumeOffer`'s.
struct AgentResumeBar: View {
    @ObserveInjection private var inject
    let offer: AgentResumeOffer
    let resume: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: offer.canResume ? "arrow.clockwise" : "clock.badge.xmark")
                .font(.system(size: 11))
                .foregroundStyle(offer.canResume ? Color.accent : Color.textFaint)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentResumeBar.headline(for: offer))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Text(AgentResumeBar.detail(for: offer))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if offer.canResume {
                action("Resume", emphasis: true, run: resume)
            }
            action(offer.canResume ? "Not Now" : "Dismiss", emphasis: false, run: dismiss)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceRaised)
        .overlay(alignment: .bottom) { Color.border.frame(height: 1) }
        .enableInjection()
    }

    /// What the band says, as a pure function so the sentence is checkable.
    ///
    /// **A blocked offer says so plainly rather than offering a resume that will fail** — #63's
    /// own acceptance criterion. Claude Code prunes transcripts on `cleanupPeriodDays`, about
    /// 30 days by default, so this is a state a bench left alone over a holiday reaches on its
    /// own.
    static func headline(for offer: AgentResumeOffer) -> String {
        switch offer.blocked {
        case nil:
            return "\(offer.agent.command) was running here — resume it?"
        case .transcriptGone:
            return
                "\(offer.agent.command) was running here, but its transcript is gone "
                + "(Claude Code keeps about 30 days), so it cannot be resumed."
        case let .runtimeUnknown(command):
            return "\(command) was running here, and helm has no way to resume it."
        }
    }

    /// The session and the directory, which is what #63 asks the offer to name.
    static func detail(for offer: AgentResumeOffer) -> String {
        "\(offer.agent.shortSession)… in \(offer.agent.cwd)"
    }

    private func action(_ title: String, emphasis: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    emphasis ? Color.selection : Color.surface,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(emphasis ? Color.accent : Color.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

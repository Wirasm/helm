import SwiftUI

/// The one moving thing in the chat face, and the **only** place tool activity
/// appears anywhere in it — as texture, never as a name.
///
/// **Tool calls are activity, not content.** A tool call is not a message to be
/// read; it is evidence the agent is alive. So it renders as a mark on a tape
/// and never as a line saying "called Edit", in any collapsed or greyed form.
///
/// **The tape is ruled in seconds and drifts on the clock, not on the file.**
/// That is the whole answer to the measured median **8.83 s** before a turn's
/// first record reaches disk (75% of turns open with >5 s of nothing, 26.5% with
/// >15 s): there is genuinely nothing to draw, and the tape is visibly alive
/// anyway. A spinner would say the same thing; a tape ruled in real seconds also
/// shows *how long*, and each beat that lands leaves a mark that ages away.
struct ChatTicker: View {
    let beats: [Date]
    let since: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reduced motion still moves — it has to, that is the component's whole
        // job — but at 1 Hz, which reads as a clock rather than a drift.
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 1.0 / 20.0)) { context in
            HStack(spacing: 13) {
                Text("working")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
                ChatTickerTape(now: context.date, beats: beats)
                    .frame(width: 136, height: 15)
                Text(elapsed(to: context.date))
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.textMuted.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The agent is working")
    }

    private func elapsed(to now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(since ?? now)))
        if seconds < 60 { return "\(seconds)s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A time axis with the agent's work marked on it. Newest at the right; marks
/// age leftward and dissolve off the edge.
private struct ChatTickerTape: View {
    let now: Date
    let beats: [Date]

    var body: some View {
        Canvas { context, size in
            let window = ChatModel.tickerWindow
            let perSecond = size.width / window
            let middle = (size.height / 2).rounded()
            let instant = now.timeIntervalSince1970

            context.fill(
                Path(CGRect(x: 0, y: middle, width: size.width, height: 1)),
                with: .color(Color.textMuted.opacity(0.2)))

            // One tick per second of tape. These are the motion — they exist
            // whether or not the agent has written anything, which is the case
            // this component was built for.
            var second = (instant - window).rounded(.up)
            while second <= instant {
                let x = size.width - (instant - second) * perSecond
                context.fill(
                    Path(CGRect(x: x, y: middle - 3, width: 1, height: 4)),
                    with: .color(Color.textMuted.opacity(0.5)))
                second += 1
            }

            // One mark per content block that landed. A beat, never a name.
            for beat in beats {
                let age = now.timeIntervalSince(beat)
                guard age >= 0, age <= window else { continue }
                let x = size.width - age * perSecond
                context.fill(
                    Path(CGRect(x: x - 0.75, y: middle - 5, width: 1.5, height: 11)),
                    with: .color(Color.accent.opacity(0.2 + 0.8 * (1 - age / window))))
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.22),
                    .init(color: .black, location: 1),
                ], startPoint: .leading, endPoint: .trailing))
    }
}

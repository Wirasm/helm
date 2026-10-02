import HelmWire
import SwiftUI

/// The top of the Sessions drawer (M1, #357): every agent that needs the operator, one row each,
/// asking first, then finished, then mail, the oldest first in each. "mine" is his own; "all" adds
/// finished turns addressed to the agents that spawned them. A click goes to the pane, as his own
/// gesture, which is what marks a finished turn seen. Nothing here closes anything.
struct NeedsYouSection: View {
    @ObservedObject var foregrounds: SessionForegrounds
    let go: (AttentionItem) -> Void
    @State private var all = false

    var body: some View {
        let items = NeedsYou.rows(foregrounds.attention, all: all)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("needs you").foregroundStyle(Color.textMuted)
                Spacer()
                scope("mine", isOn: !all) { all = false }
                scope("all", isOn: all) { all = true }
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            if items.isEmpty {
                Text("nothing")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 5)
            }
            ForEach(items) { item in
                NeedsYouRow(item: item) { go(item) }
            }
            Color.border.frame(height: 1)
        }
    }

    private func scope(_ name: String, isOn: Bool, pick: @escaping () -> Void) -> some View {
        Button(name, action: pick)
            .buttonStyle(.chrome)
            .foregroundStyle(isOn ? Color.textPrimary : Color.textFaint)
    }
}

/// One thing an agent needs: its glyph, who, a few of its own words, how long ago.
private struct NeedsYouRow: View {
    let item: AttentionItem
    let go: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(item.kind.glyph).foregroundStyle(item.kind.color)
            Text(item.who).foregroundStyle(Color.textPrimary).lineLimit(1)
            Text(item.words ?? "")
                .foregroundStyle(Color.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(BenchSessionRow.age(sinceMs: NeedsYou.ms(item.since), now: Date()))
                .foregroundStyle(Color.textFaint)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .opacity(item.mine ? 1 : 0.5)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: go)
        .help(item.kind.help(1) + (item.pane == nil ? "" : ": click to go there"))
    }
}

/// What the section lists, pure so it is testable without a view.
enum NeedsYou {
    /// His own items, or all of them, in the walk's order.
    static func rows(_ items: [AttentionItem], all: Bool) -> [AttentionItem] {
        all ? items : items.filter(\.mine)
    }

    static func ms(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 * 1000))
    }
}

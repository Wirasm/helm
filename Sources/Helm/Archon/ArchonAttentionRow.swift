import SwiftUI

/// One item of the attention queue: its workflow, how long it has waited, the first line of
/// Archon's question and the numbered answers. Expanded, the whole question.
///
/// **The question is markdown**, written to be read by whoever answers it: what is decided, why
/// it matters, a recommendation with evidence, what each choice does and what waiting costs.
/// Collapsed shows its first line, which the SDLC stages make the headline.
struct ArchonAttentionRow: View {
    let item: ArchonAttentionItem
    let isSelected: Bool
    let isExpanded: Bool
    let isBusy: Bool
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(item.workflow)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 170, alignment: .leading)
                Text(waitLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if isBusy { ProgressView().controlSize(.mini) }
                Spacer(minLength: 8)
                CopyableLabel(value: item.runId, hint: "Click to copy the run id — \(item.runId)") {
                    Text(ArchonRun.shortID(of: item.runId))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.textFaint)
                }
            }
            Group {
                if isExpanded {
                    Text(Self.markdown(item.message))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(Self.markdown(Self.headline(of: item.message)))
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.textPrimary)
            .padding(.leading, 180)
            if !item.choices.isEmpty { choices }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.archonSurfaceRaised : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    private var choices: some View {
        HStack(spacing: 12) {
            ForEach(Array(item.choices.prefix(9).enumerated()), id: \.offset) { index, choice in
                Text("\(index + 1) \(choice.label)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.attention)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 180)
    }

    /// What kind of wait, and for how long.
    private var waitLine: String {
        let since = item.pausedAt.map { " · " + ArchonRunRow.age(since: $0) } ?? ""
        switch item.ask {
        case let .question(node, _, _, _, _), let .gate(node, _, _): return node + since
        case .usageLimit: return "usage limit" + since
        case .unreadable: return "unreadable" + since
        case let .unknown(kind): return kind + since
        }
    }

    private var tint: Color {
        switch item.ask {
        case .question, .gate: .attention
        case .unreadable, .unknown: .danger
        case .usageLimit: .textMuted
        }
    }

    /// The first line with text on it.
    static func headline(of message: String) -> String {
        message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
    }

    /// Inline markdown with its line breaks kept: bold, code and links render, and the bullet
    /// lists stay one choice per line.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

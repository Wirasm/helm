import SwiftUI
import UIKit

/// A message's text the operator can select part of and copy, or copy whole with "Copy message"
/// in the same menu. A read-only `UITextView`: SwiftUI's `Text` on iOS copies only the whole
/// text, never a span. It sizes to its text at the width it is offered and never scrolls itself.
///
/// Its size is measured on a text view of its own, never the one on screen: that one's answer
/// depends on its current frame, and a lazy stack that measures, places and measures again then
/// never settles (the chat hung at 100% CPU).
struct SelectableText: UIViewRepresentable {
    let text: String
    /// Drawn as markdown, blocks and all (`ChatText.markdown`), rather than as written.
    var markdown = false
    let font: UIFont
    let color: Color
    /// At most this many lines, cut at the end (0 for all); a selection still copies all of it.
    var lines = 0
    /// What "Copy message" copies, when not the text as drawn: the message as the agent wrote it.
    var copy: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = Self.textView(lines: lines)
        view.isSelectable = true
        view.tintColor = UIColor(Palette.finished)
        view.linkTextAttributes = [.foregroundColor: UIColor(Palette.finished)]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    /// Sets the text only when it changed. Asking the view whether it did is no answer: it keeps
    /// the text with attributes of its own, so it never equals what it was given, and every set
    /// relays the stack out, which updates the view again.
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.whole = copy ?? text
        let styled = context.coordinator.styled(self)
        guard context.coordinator.applied !== styled else { return }
        context.coordinator.applied = styled
        view.attributedText = styled
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: UITextView, context: Context
    )
        -> CGSize?
    {
        context.coordinator.size(of: self, width: proposal.width ?? .greatestFiniteMagnitude)
    }

    /// A read-only text view with no inset, no padding and no scrolling, `lines` deep.
    private static func textView(lines: Int) -> UITextView {
        let view = MessageTextView()
        view.isAccessibilityElement = true
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.maximumNumberOfLines = lines
        view.textContainer.lineBreakMode = lines == 0 ? .byWordWrapping : .byTruncatingTail
        return view
    }

    /// Where every message is measured: never on screen, never resized.
    @MainActor private static let measure = textView(lines: 0)

    final class Coordinator: NSObject, UITextViewDelegate {
        private var shown: (text: String, styled: NSAttributedString)?
        /// The size at each width offered, for what is shown.
        private var sizes: [CGFloat: CGSize] = [:]
        /// What the view on screen was last given.
        var applied: NSAttributedString?
        /// What "Copy message" copies.
        var whole = ""

        /// The text styled, styled again only when it changed.
        func styled(_ view: SelectableText) -> NSAttributedString {
            if let shown, shown.text == view.text { return shown.styled }
            let color = UIColor(view.color)
            let styled =
                view.markdown
                ? ChatText.markdown(view.text, font: view.font, color: color)
                : NSAttributedString(
                    string: view.text, attributes: [.font: view.font, .foregroundColor: color])
            shown = (view.text, styled)
            sizes = [:]
            return styled
        }

        @MainActor func size(of view: SelectableText, width: CGFloat) -> CGSize {
            let styled = styled(view)
            if let size = sizes[width] { return size }
            let measure = SelectableText.measure
            measure.textContainer.maximumNumberOfLines = view.lines
            measure.textContainer.lineBreakMode =
                view.lines == 0 ? .byWordWrapping : .byTruncatingTail
            measure.attributedText = styled
            let fit = measure.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            let size = CGSize(width: min(ceil(fit.width), width), height: ceil(fit.height))
            sizes[width] = size
            return size
        }

        /// The system's actions for the selection, and "Copy message" for the whole of it.
        func textView(
            _ view: UITextView, editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            let whole = whole
            let copyAll = UIAction(title: "Copy message") { _ in
                UIPasteboard.general.string = whole
            }
            return UIMenu(children: suggestedActions + [copyAll])
        }
    }
}

/// A message's text view, one accessibility element as SwiftUI's `Text` is. A plain `UITextView`
/// lists each paragraph and link as an element of its own, and an accessibility client walking a
/// long chat (VoiceOver, an XCUITest snapshot) then costs about three times the CPU while it
/// scrolls.
private final class MessageTextView: UITextView {
    override var accessibilityElements: [Any]? {
        get { [] }
        set {}
    }
}

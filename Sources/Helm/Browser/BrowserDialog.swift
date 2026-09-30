import SwiftUI

/// A page's `alert`, `confirm`, `prompt` or `beforeunload`, waiting for the operator (#544).
///
/// **Only the session Chrome told can answer it**, and detaching that session leaves the dialog
/// unanswerable and the tab, and every tab of the same site, stopped for good (measured against
/// Chrome 154). So the dialog carries its session, and the pane keeps that session attached until
/// the dialog closes.
struct BrowserDialog: Hashable {
    enum Kind: String {
        case alert, confirm, prompt, beforeunload
    }

    let kind: Kind
    let message: String
    /// What a `prompt`'s field starts with.
    let defaultPrompt: String
    let session: String

    init(kind: Kind, message: String, defaultPrompt: String = "", session: String) {
        self.kind = kind
        self.message = message
        self.defaultPrompt = defaultPrompt
        self.session = session
    }

    /// A type this build does not know is shown as a `confirm`: both answers stay possible.
    init(_ opening: DialogOpening, session: String) {
        self.init(
            kind: Kind(rawValue: opening.type) ?? .confirm, message: opening.message,
            defaultPrompt: opening.defaultPrompt ?? "", session: session)
    }
}

/// `Page.javascriptDialogOpening`'s params.
struct DialogOpening: Decodable {
    let type: String
    let message: String
    let defaultPrompt: String?
}

/// The dialog on show, drawn over the top of the page like Chrome's own.
///
/// **It takes the keyboard only from its own page** (`takesKeyboard`): a dialog in a pane the
/// operator is not typing in waits for him to click, rather than moving his keyboard (#125).
struct BrowserDialogStrip: View {
    let dialog: BrowserDialog
    let takesKeyboard: Bool
    /// The answer, and whether the strip held the keyboard when it was given, so the pane can
    /// hand the keyboard back to the page.
    let answer: (_ accept: Bool, _ text: String?, _ hadKeyboard: Bool) -> Void

    @State private var text: String
    @FocusState private var focus: Focus?

    private enum Focus { case field, strip }

    init(
        dialog: BrowserDialog, takesKeyboard: Bool,
        answer: @escaping (_ accept: Bool, _ text: String?, _ hadKeyboard: Bool) -> Void
    ) {
        self.dialog = dialog
        self.takesKeyboard = takesKeyboard
        self.answer = answer
        _text = State(initialValue: dialog.defaultPrompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textMuted)
            if !dialog.message.isEmpty {
                ScrollView {
                    Text(dialog.message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
            if dialog.kind == .prompt {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .field)
                    .onSubmit { reply(true) }
            }
            HStack(spacing: 8) {
                Spacer()
                if dialog.kind != .alert {
                    Button(dialog.kind == .beforeunload ? "Stay" : "Cancel") { reply(false) }
                }
                Button(dialog.kind == .beforeunload ? "Leave" : "OK") { reply(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: 440)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.border))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .padding(12)
        .focusable(dialog.kind != .prompt)
        .focusEffectDisabled()
        .focused($focus, equals: .strip)
        .onKeyPress(.return) {
            reply(true)
            return .handled
        }
        // Escape is Cancel, and an alert's only answer.
        .onExitCommand { reply(dialog.kind == .alert) }
        .onAppear {
            if takesKeyboard { focus = dialog.kind == .prompt ? .field : .strip }
        }
    }

    private func reply(_ accept: Bool) {
        answer(accept, accept ? text : nil, focus != nil)
    }

    private var heading: String {
        switch dialog.kind {
        case .alert, .confirm, .prompt: "The page says"
        case .beforeunload: "Leave this page? Changes you made may not be saved."
        }
    }
}

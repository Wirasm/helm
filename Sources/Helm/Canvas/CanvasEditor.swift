import SwiftUI

// MARK: - Somebody else's bytes

/// The file changed under an open draft, and helm did not do it (#289).
///
/// **A type rather than a `Bool`, because the bytes are the evidence and both ways out are
/// expressed against them.** `CanvasModel.takeTheirs` adopts *this* string rather than re-reading
/// the file, so the version the operator accepts is exactly the version the strip told him about
/// — re-reading at the moment of the click would hand him a third version he never saw. A flag
/// could not do that, and a bare `String?` would say nothing at the call site about what the
/// string is.
///
/// **Held only while a conflict is live.** A newer write replaces it, so the strip is always about
/// the newest thing helm has seen; resolving it clears it.
struct CanvasConflict: Equatable {
    /// What was on disk when helm noticed.
    let theirs: String
}

// MARK: - What is in the editor, and what is on disk

/// The open draft: what the operator has typed, what helm last saw on disk, and — when somebody
/// else has written the file since — what is there now.
///
/// **Two strings rather than one plus a dirty flag**, because the interesting question is not
/// *"has something changed"* but *"is what I am looking at what is in the file"* — and the honest
/// answer to that is a comparison, not a bit somebody has to remember to set. A flag has two
/// writers (typing sets it, saving clears it) and a save that fails halfway through clearing it is
/// a note the operator believes is written.
///
/// `saved` moves only when a write **succeeded**, so a failed save leaves `isDirty` true and the
/// next keystroke schedules another attempt. That is the whole of "saving must not lose work":
/// nothing is ever thrown away on the strength of a write helm did not see finish.
///
/// **And `saved` is what makes the second writer detectable at all**, which is why widening the
/// scope to every markdown canvas (#289) needed no second mechanism. It is *what helm believes is
/// on disk* — so bytes on disk that differ from it are, by definition, bytes helm did not put
/// there. `CanvasModel.reconcile` is that one comparison.
struct CanvasDraft: Equatable {
    /// What is in the editor right now.
    var text: String
    /// What helm believes is on disk — what it wrote, or what it read when the editor opened.
    var saved: String
    /// When `saved` was written. nil until the first successful save, which is also the state a
    /// file the operator has typed nothing into is in.
    var savedAt: Date?
    /// Somebody else's bytes, when there are some. nil the rest of the time, which is every draft
    /// on a file only helm is writing.
    var conflict: CanvasConflict?

    var isDirty: Bool { text != saved }

    /// Whether this draft is still holding something nobody has decided about.
    ///
    /// **`isDirty` alone is not that question once a conflict exists, and reading it as though it
    /// were is a third way out of a conflict that presses neither button.** A conflict raised
    /// while the operator was typing survives him undoing back to what helm last wrote — at that
    /// moment `text == saved`, so `isDirty` is false while the strip is still up, and a guard
    /// spelled `isDirty` would let `read()` drop the draft and take the strip with it. helm would
    /// then have decided the conflict itself, silently, which is the one thing the two buttons
    /// exist to stop it doing.
    ///
    /// A property on the value rather than a compound condition at the call site, because it was
    /// a *comment* claiming `saveDraft` guaranteed this "by construction" that carried it before —
    /// and the two fields are independent, so nothing did.
    var isUnresolved: Bool { isDirty || conflict != nil }

    /// What the footer says about the file, in the operator's terms.
    ///
    /// **"Not saving" comes first and outranks "Unsaved", because they are different promises.**
    /// Unsaved means helm is about to write; not saving means it has stopped and is waiting to be
    /// told what to do. A footer that said the first while meaning the second is the reassurance
    /// that makes an operator walk away from a conflict.
    ///
    /// **It says "Unsaved" while a save is merely pending, and that is deliberate rather than
    /// pessimistic wording.** helm writes a beat after typing stops, so for most of a sentence the
    /// file on disk genuinely is behind the screen.
    ///
    /// A property on the value rather than a string built in the view, so the rule is reachable
    /// from `swift test` and there is one place it is written.
    var status: String {
        if conflict != nil { return "Not saving" }
        if isDirty { return "Unsaved" }
        guard let savedAt else { return "No changes" }
        return "Saved \(Self.timeFormatter.string(from: savedAt))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - The writing face

/// A markdown canvas the operator is writing in: the source in a plain text view, with the file's
/// own path under it.
///
/// **A `TextEditor` over the markdown source, not an editable rendering — and the reason is what
/// the two things ARE.** A markdown canvas is a page helm *generates*: `marked` converts the
/// artifact and writes the result into `innerHTML`. Making that editable would mean turning HTML
/// back into markdown on every keystroke, which is a lossy round trip over a document nobody asked
/// helm to reformat. The markdown text *is* the file, so editing it is the identity operation —
/// what is typed is what is written, byte for byte, and `Read` renders it with exactly the
/// renderer that has always rendered it.
///
/// **It also means the annotation bridge is not involved at all.** With a marking tool held,
/// dragging over text on the page is a mark; this surface never has the page on screen, and the
/// header hides the picker while a draft is open. `.read` being the default tool (#302/#306) is
/// what made an inert canvas possible in the first place, and an inert canvas is the precondition
/// this whole surface was waiting on.
struct CanvasEditorView: View {
    @ObservedObject var model: CanvasModel
    let file: EditableFile
    let draft: CanvasDraft

    /// **The point of ⌘⇧N is that the cursor is already in it.** A new note that needs a click
    /// before it takes a character is a blank pane, not a place to think.
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                // `TextEditor` paints its own AppKit background, which is the fourth colour source
                // `Design/Palette.swift` exists to have removed. Hiding it lets `surface` through
                // — the same plane the rendered canvas and the terminal are on.
                .scrollContentBackground(.hidden)
                .background(Color.surface)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .focused($writing)
                // **`.task`, not `.onAppear`, and that is a measurement rather than a style
                // choice.** A `TextField` takes focus assigned during `onAppear` — the canvas
                // address bar has done exactly that since ⌘L existed — and a `TextEditor` does
                // not: its `NSTextView` is not in the window's responder chain yet at that
                // point, so the assignment lands on nothing and is silently dropped. Driven
                // live against the real app, both ways: with `onAppear`, ⇧⌘N opened the editor
                // and every character typed after it went nowhere at all, while the very same
                // keystrokes reached the address bar's field in the same window a moment later.
                // `.task` runs after the first render pass, by which point the responder exists.
                .task { writing = true }
            Color.border.frame(height: 1)
            footer
        }
        .background(Color.surface)
    }

    /// The editor writes through the model, never into a local `@State`.
    ///
    /// A `@State` copy would be a second place the text lives, and the one that is not saved. The
    /// model owns the draft because it also owns the file, the save timer and the watcher — and
    /// because it outlives this view, which SwiftUI rebuilds on any churn in a sibling pane.
    private var text: Binding<String> {
        Binding(get: { draft.text }, set: { model.edit($0) })
    }

    /// **The path, in full, and copyable — because handing it over is the point of the feature.**
    /// The operator's own words in #289 are *"I can just send the path to you of the file"*, so
    /// the minimum this surface owes him is a path he can read and take.
    ///
    /// **It is not put on the clipboard when the file is opened for writing.** Editing is not
    /// asking for the clipboard to change, and a clipboard that changes under an act nobody asked
    /// for destroys whatever was in it. `CopyableLabel` is the affordance the canvas header
    /// already uses for exactly this, so the gesture is one the operator has already learned here.
    private var footer: some View {
        let path = Pasteboard.path(of: file.url)
        return HStack(spacing: 8) {
            CopyableLabel(value: path, hint: "Click to copy \(path)") {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(draft.status)
                .font(.system(size: 10))
                .foregroundStyle(draft.isDirty ? Color.textFaint : Color.textMuted)
                .fixedSize()
        }
        .foregroundStyle(Color.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.surfaceRaised)
    }
}

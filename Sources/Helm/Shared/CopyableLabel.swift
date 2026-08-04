import AppKit
import SwiftUI

/// A label you click to put a longer value on the clipboard.
///
/// **`value` and the label are separate arguments on purpose, and that asymmetry is the
/// whole point of the type.** Every surface that wants this shows a *shortened* form of
/// something longer — the Archon rail renders eight characters of a 32-character run id, a
/// canvas header renders a filename standing in for a path. Copying what is rendered
/// produces a string that looks right, pastes cleanly, and then fails every command it is
/// pasted into, which is the worst shape a bug can take. Written as
/// `CopyableLabel(value: run.id) { Text(run.shortID) }` the two are visibly different things
/// at the call site, so the mistake has to be typed rather than merely forgotten.
///
/// **The feedback is not decoration.** A copy that says nothing is indistinguishable from a
/// dead click, so the operator clicks again to be sure — and the two surfaces this serves are
/// both *labels*, which have never been clickable and so carry no learned expectation to lean
/// on. The two existing copy affordances (`ArtifactBrowser`, `WorkspaceBar`) get their
/// acknowledgement for free because a context menu dismisses itself; nothing here does.
///
/// So: **hover says it is clickable, the badge says it happened.** The hover fill is
/// `Color.selection`, the same token the workspace bar spends on its selected pill, plus a
/// pointing-hand cursor; the badge is a small "Copied" chip overlaid on the label for a beat.
/// An overlay rather than a swap of the label's own text, because a swap changes the label's
/// width and makes the row twitch at the moment the operator is looking straight at it.
///
/// **One treatment, spent at every site.** Two labels that copy in two different ways is the
/// interaction version of the three colour sources the palette slice exists to have removed;
/// if a surface needs something else, change it here for all of them.
struct CopyableLabel<Label: View>: View {
    /// What lands on the pasteboard. Not what is drawn — see the type's note.
    let value: String
    /// The tooltip before the click. Say what will be copied, in full: it is the one place
    /// the operator can read the whole value without taking it.
    let hint: String
    @ViewBuilder var label: () -> Label

    @State private var hovering = false
    @State private var copied = false
    /// Bumped per click, so `.task(id:)` restarts the badge's timer instead of an earlier
    /// click's timer clearing a later click's badge.
    @State private var copies = 0
    /// **`NSCursor` push/pop is a stack AppKit will not unwind for you** — the lesson
    /// `SplitStack` records at length. A row that is removed while the pointer rests on it
    /// gets no exit event, so `onDisappear` has to pop, and this flag is what keeps that from
    /// popping an entry this view never pushed.
    @State private var pushedCursor = false

    var body: some View {
        label()
            .padding(.horizontal, 4)  // room for the hover fill, so it is not flush to the glyphs
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(hovering ? Color.selection : .clear)
            )
            .overlay { badge }
            .contentShape(RoundedRectangle(cornerRadius: 3))
            .onTapGesture { take() }
            .onHover { inside in
                hovering = inside
                if inside { pushCursor() } else { popCursor() }
            }
            .onDisappear { popCursor() }
            .help(hint)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: copied)
            // Keyed on the click count: a second click restarts the beat rather than
            // inheriting the remains of the first one's.
            .task(id: copies) {
                guard copies > 0 else { return }
                copied = true
                try? await Task.sleep(for: .milliseconds(1100))
                guard !Task.isCancelled else { return }
                copied = false
            }
    }

    /// Small enough to sit inside the row it covers. `runningLine` in the rail is `.clipped()`
    /// — it has to be, for the stage subline's slide-in — so a badge taller than the row would
    /// be shaved off at the top and bottom rather than floating above it.
    @ViewBuilder
    private var badge: some View {
        if copied {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .bold))
                Text("Copied")
                    .font(.system(size: 8.5, weight: .semibold))
            }
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.surfaceRaised))
            .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
            .fixedSize()
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func take() {
        Pasteboard.copy(value)
        copies += 1
    }

    private func pushCursor() {
        guard !pushedCursor else { return }
        pushedCursor = true
        NSCursor.pointingHand.push()
    }

    private func popCursor() {
        guard pushedCursor else { return }
        pushedCursor = false
        NSCursor.pop()
    }
}

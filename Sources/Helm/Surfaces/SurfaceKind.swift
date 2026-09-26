import SwiftUI

// MARK: - SurfaceKind

/// What one kind of pane is: how its live object is made, drawn, shown on a tab and let go.
///
/// **The one place a pane kind is handled** (`bench-architecture.md`, primitive 2: a surface is
/// what a pane shows; new kinds plug in at the edge). Before this, every kind lived in five
/// places — a cache per kind (`TerminalManager.sessions`, `WorkbenchModel.canvases`,
/// `.browsers`), a `switch pane.content` in `SlotTabStrip`, `SlotView` and
/// `WorkbenchModel.close`, a teardown per kind, and a tab view per kind. A kind now conforms
/// here, in its own slice, and registers once; nothing in `Workbench/` asks what kind a pane is.
///
/// A kind is an object rather than a type with statics because the ones helm has need wiring
/// from whoever registers them: the terminal kind needs its manager's controller, the canvas kind
/// the bench's mark route, the browser kind a factory a test can point at a scratch root.
@MainActor
protocol SurfaceKind: AnyObject {
    associatedtype Model: AnyObject

    /// Which `Pane.Content` this kind renders.
    var kind: Pane.Content.Kind { get }

    /// The live object for a pane that has none yet. nil when the kind cannot make one here —
    /// a terminal with no workspace to run in.
    func make(for pane: Pane, in workspace: WorkspacePath?) -> Model?

    /// The pane's body.
    func view(of model: Model, in slot: SurfaceSlot) -> AnyView

    /// The pane's tab: the kind supplies the mark and the title, `PaneTab` supplies the chrome.
    func tab(of model: Model, in slot: SurfaceSlot) -> AnyView

    /// Let the model go: flush, stop watching, close a connection. Called exactly once per
    /// model, when its pane leaves benchd's document — closed, or its workspace closed.
    func close(_ model: Model)
}

/// What a surface needs to know about where it is drawn — the bench's answers, asked by the bench.
struct SurfaceSlot {
    let pane: Pane
    /// The focused slot's selected pane: the one the keyboard belongs to.
    let holdsKeyboard: Bool
    let isSelected: Bool
    /// The bench's rule, not the slot's: a pane can close unless it is the bench's last.
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
}

// MARK: - SurfaceRegistry

/// Every live pane object, of every kind, in one place — keyed by pane id, stamped with the
/// workspace it belongs to, and let go through its kind.
///
/// **Ordered**, because `TerminalManager.sessions` was an array its readers depend on (tab
/// ordinals, the snapshot's order).
///
/// **Publishes on lifecycle, not on lazy resolution.** `adopt` and `close` send
/// `objectWillChange`; `resolve` creating a canvas or a browser model the first time a view
/// asks for it does not, because that happens inside a SwiftUI body, and publishing from there is
/// a change during a view update. Nothing observing the registry cares about that creation: it
/// adds no pane, only the render of one that was already there.
@MainActor
final class SurfaceRegistry: ObservableObject {
    struct Entry {
        let id: Pane.ID
        let kind: Pane.Content.Kind
        let workspace: WorkspacePath?
        let model: AnyObject
    }

    private(set) var entries: [Entry] = []
    private var kinds: [Pane.Content.Kind: AnyKind] = [:]

    /// Register a kind, replacing any earlier one for the same `Pane.Content.Kind` — which is
    /// how a test puts a fake in and how a second `WorkbenchModel` on one manager rewires the
    /// canvas route to itself.
    func register<K: SurfaceKind>(_ kind: K) {
        kinds[kind.kind] = AnyKind(kind)
    }

    // MARK: Reading

    func existing<M: AnyObject>(_ id: Pane.ID, as _: M.Type = M.self) -> M? {
        entries.first { $0.id == id }?.model as? M
    }

    func models<M: AnyObject>(_: M.Type = M.self) -> [M] {
        entries.compactMap { $0.model as? M }
    }

    func models<M: AnyObject>(_: M.Type = M.self, in workspace: WorkspacePath) -> [M] {
        entries.filter { $0.workspace == workspace }.compactMap { $0.model as? M }
    }

    // MARK: Lifecycle

    /// The pane's model, made on first use. nil when no kind is registered for it, or the kind
    /// cannot make one here.
    func resolve(_ pane: Pane, in workspace: WorkspacePath?) -> AnyObject? {
        if let entry = entries.first(where: { $0.id == pane.id }) { return entry.model }
        guard let kind = kinds[pane.content.kind],
            let model = kind.make(pane, workspace)
        else { return nil }
        entries.append(
            Entry(id: pane.id, kind: pane.content.kind, workspace: workspace, model: model))
        return model
    }

    /// Take in a model made before its pane existed — a terminal, whose session is created first
    /// and names the pane (`Pane.id` IS the session id).
    func adopt(
        _ model: AnyObject, as id: Pane.ID, kind: Pane.Content.Kind, in workspace: WorkspacePath
    ) {
        objectWillChange.send()
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, kind: kind, workspace: workspace, model: model))
    }

    func close(_ id: Pane.ID) {
        release { $0.id == id }
    }

    private func release(where leaving: (Entry) -> Bool) {
        let gone = entries.filter(leaving)
        guard !gone.isEmpty else { return }
        objectWillChange.send()
        entries.removeAll(where: leaving)
        for entry in gone { kinds[entry.kind]?.close(entry.model) }
    }

    // MARK: Drawing

    func view(of pane: Pane, in slot: SurfaceSlot, workspace: WorkspacePath?) -> AnyView? {
        guard let kind = kinds[pane.content.kind], let model = resolve(pane, in: workspace)
        else { return nil }
        return kind.view(model, slot)
    }

    func tab(of pane: Pane, in slot: SurfaceSlot, workspace: WorkspacePath?) -> AnyView? {
        guard let kind = kinds[pane.content.kind], let model = resolve(pane, in: workspace)
        else { return nil }
        return kind.tab(model, slot)
    }
}

/// A registered kind with its model type erased — the one place the registry casts, and it casts
/// back to the type the kind itself made. It holds the kind strongly: the registry owns its
/// kinds, and a kind that needs its owner (the terminal kind's manager, the canvas kind's bench)
/// holds that weakly or unowned.
@MainActor
private struct AnyKind {
    let make: (Pane, WorkspacePath?) -> AnyObject?
    let view: (AnyObject, SurfaceSlot) -> AnyView
    let tab: (AnyObject, SurfaceSlot) -> AnyView
    let close: (AnyObject) -> Void

    init<K: SurfaceKind>(_ kind: K) {
        make = { pane, workspace in kind.make(for: pane, in: workspace) }
        view = { model, slot in
            guard let model = model as? K.Model else { return AnyView(EmptyView()) }
            return kind.view(of: model, in: slot)
        }
        tab = { model, slot in
            guard let model = model as? K.Model else { return AnyView(EmptyView()) }
            return kind.tab(of: model, in: slot)
        }
        close = { model in
            if let model = model as? K.Model { kind.close(model) }
        }
    }
}

// MARK: - PaneTab

/// Every tab's chrome: the mark, the title, the close button, the selection. It was written out
/// three times — `TerminalTab`, `CanvasTab`, `BrowserTabLabel` — identical but for the mark,
/// the title and the close button's tooltip, which is what a kind now supplies.
struct PaneTab<Mark: View>: View {
    let title: String
    let truncation: Text.TruncationMode
    let closeHelp: String
    let slot: SurfaceSlot
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        HStack(spacing: 5) {
            mark()
            Text(title)
                .font(.system(size: 11.5, weight: slot.isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(truncation)
                .frame(maxWidth: 180)

            Button(action: slot.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .disabled(!slot.canClose)
            .opacity(slot.canClose ? 1 : 0.3)
            .help(slot.canClose ? closeHelp : "The last pane cannot be closed")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(slot.isSelected ? Color.selection : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: slot.select)
    }
}

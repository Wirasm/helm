import HelmWire
import SwiftUI

/// What ⇧⌘O, the workspace bar's `+` and the empty bench's button ask: which folder on benchd's
/// machine to work in (M5c, #459). One sheet, so the three cannot disagree.
///
/// **A typed path and a short list, not a file browser.** Finder's panel could only show the
/// Mac's disk, and the folders that matter are on the agents' machine. benchd resolves what is
/// typed there, `~` included (`BenchPathField`), and the list is the project roots benchd's prp
/// stores record: every project an agent has written a plan for, which is most of where the
/// operator works. A root in the list goes through the same check, since its folder may be gone.
///
/// One path on one machine too, so the sheet the operator uses daily is the one a remote bench
/// needs.
struct WorkspacePicker: View {
    let prp: PrpStores
    /// Open the folder benchd resolved.
    let open: (String) -> Void
    let dismiss: () -> Void

    /// Read once, in `init`: a sheet sizes itself from its first layout (#50). Blocking here is
    /// cheap, since `prp/stores` without a workspace reads each store's `project.json` and walks
    /// no files.
    @State private var roots: Result<[String], PrpStores.Failure>
    @State private var failure: String?

    init(prp: PrpStores, open: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
        self.prp = prp
        self.open = open
        self.dismiss = dismiss
        _roots = State(initialValue: Self.knownRoots(prp))
    }

    /// The project roots benchd's stores record, each once, in the stores' order (by name).
    static func knownRoots(_ prp: PrpStores) -> Result<[String], PrpStores.Failure> {
        prp.stores().map { found in
            var seen = Set<String>()
            return found.stores.compactMap(\.path).filter { seen.insert($0).inserted }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open a workspace")
                .font(.system(size: 13, weight: .semibold))
            BenchPathField(
                prompt: "Folder path on benchd's machine, ~ is its home", wants: .directory,
                prp: prp, onResolved: chosen)
            rootList
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .foregroundStyle(Color.textPrimary)
        .background(Color.surface)
    }

    @ViewBuilder private var rootList: some View {
        switch roots {
        case let .failure(why):
            note("Could not ask benchd for known projects: \(why.reason)")
        case let .success(roots) where roots.isEmpty:
            note("No known projects yet: a project appears here once an agent writes to ~/.prp.")
        case let .success(roots):
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(roots, id: \.self) { root in
                        Button {
                            pick(root)
                        } label: {
                            Text(root)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.chrome)
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 260)
            if let failure { note(failure) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pick(_ root: String) {
        switch prp.resolve(root, as: .directory) {
        case let .success(path): chosen(path)
        case let .failure(why): failure = why.reason
        }
    }

    private func chosen(_ path: String) {
        dismiss()
        open(path)
    }
}

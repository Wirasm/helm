import SwiftUI

/// The history tab: kilds that have stopped.
///
/// An earlier version of this file carried machinery for pre-rename archives — records that
/// decoded cleanly but held nothing, because the engine's view mapping renames nothing and
/// their agent handles were stranded in a room-era `participants` field. It explained, per
/// empty state, why 179 of 184 records could not be attributed to any project.
///
/// That was the wrong fix. Those records were obsolete, not misread, and the right answer
/// was to drop them rather than build a careful rendering of nothing. They have been moved
/// out of `$KILD_HOME/kilds`. This view now assumes an archive whose records mean something,
/// which is the only kind worth building against.
struct ArchiveColumn: View {
    let archived: [ArchivedKild]
    @Binding var selection: Kild.ID?
    @Binding var query: String

    var body: some View {
        VStack(spacing: 0) {
            TextField("search archive", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            if archived.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text(query.isEmpty ? "no archived kilds" : "no match for “\(query)”")
                    if !query.isEmpty {
                        // Worth saying: the archive carries no log by design, so the
                        // absence of a prose match is a property of the data, not a
                        // shortcoming of the search.
                        Text("search covers names, worktrees and agents")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(archived) { ArchivedRow(kild: $0) }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct ArchivedRow: View {
    let kild: ArchivedKild

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(kild.name).lineLimit(1).truncationMode(.middle)
                if let landed = kild.landed {
                    // The most substantive thing a stopped kild retains: what it merged.
                    Text(
                        "landed \(landed.commits) commit\(landed.commits == 1 ? "" : "s") · "
                            + "\(landed.files) file\(landed.files == 1 ? "" : "s")"
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tint)
                } else if let worktree = kild.worktree {
                    Text(worktree)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let endedAt = kild.endedAt {
                Text(Self.relative(endedAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .tag(kild.id)
    }

    /// Milliseconds since the epoch → something readable.
    ///
    /// Rendered only when `endedAt` exists. A record without one shows nothing rather than
    /// "unknown": the list already sorts the clockless last, so absence is legible from
    /// position and needs no word.
    private static func relative(_ millis: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: millis / 1000), relativeTo: Date())
    }
}

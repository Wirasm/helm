import HelmWire
import PocketKit
import SwiftUI

/// chats: a search field, then each workspace as a section that collapses, the ones that need him
/// first. A section shows its running sessions as chats (the ones asking first, then the
/// orchestrators he started, the rest dimmed), and its finished ones behind a disclosure.
struct ChatsView: View {
    @EnvironmentObject private var model: PocketModel
    let talk: (String) -> Void
    @State private var query = ""
    /// The collapsed sections' paths (`Collapsed`): kept across launches.
    @AppStorage("collapsed") private var collapsedPaths = ""
    @State private var showingFinished: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $query, prompt: Text("search").foregroundStyle(Palette.faint))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Mono.body).foregroundStyle(Palette.text)
                .padding(.horizontal, 16).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(
                        PocketHome.sections(
                            workspaces: model.workspaces, sessions: model.sessions, query: query)
                    ) { section in
                        SectionView(
                            section: section,
                            open: !Collapsed.has(section.path, collapsedPaths)
                                || !query.isEmpty,
                            showingFinished: showingFinished.contains(section.path)
                                || !query.isEmpty,
                            toggle: {
                                collapsedPaths = Collapsed.toggling(section.path, collapsedPaths)
                            },
                            toggleFinished: {
                                showingFinished.formSymmetricDifference([section.path])
                            },
                            talk: talk)
                    }
                    Failure()
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// The collapsed sections of a list, kept in `@AppStorage` as their paths, one per line.
enum Collapsed {
    static func has(_ path: String, _ paths: String) -> Bool {
        paths.split(separator: "\n").contains { $0 == path }
    }

    static func toggling(_ path: String, _ paths: String) -> String {
        var set = Set(paths.split(separator: "\n").map(String.init))
        set.formSymmetricDifference([path])
        return set.sorted().joined(separator: "\n")
    }
}

/// A workspace's header in a list: ▾ open, ▸ collapsed, ● when something needs him, a count.
struct SectionHeader: View {
    let name: String
    let open: Bool
    var needsHim = false
    let count: Int
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(open ? "▾" : "▸")
                Text(name.uppercased()).tracking(1)
                if needsHim { Text("●").foregroundStyle(Palette.asking) }
                Spacer()
                Text("\(count)")
            }
            .font(Mono.group).foregroundStyle(Palette.dim)
            .padding(.top, 10)
            .contentShape(Rectangle())
        }
    }
}

/// One workspace: its header (▾ open, ▸ collapsed, ● when something needs him), its running
/// sessions, and the finished ones behind "finished (n)".
struct SectionView: View {
    let section: PocketSection
    let open: Bool
    let showingFinished: Bool
    let toggle: () -> Void
    let toggleFinished: () -> Void
    let talk: (String) -> Void

    var body: some View {
        SectionHeader(
            name: section.name, open: open, needsHim: section.needsHim,
            count: section.running.count, toggle: toggle)
        if open {
            if section.running.isEmpty {
                Text("nothing running").font(Mono.small).foregroundStyle(Palette.faint)
            }
            ForEach(section.running) { row in
                ChatRowView(row: row)
                    .opacity(row.isOrchestrator || Attention(row) == .asking ? 1 : 0.6)
                    .onTapGesture { talk(row.id) }
            }
            if section.finishedCount > 0 {
                Button(action: toggleFinished) {
                    Text("\(showingFinished ? "▾" : "▸") finished (\(section.finishedCount))")
                        .font(Mono.small).foregroundStyle(Palette.faint)
                }
            }
            if showingFinished {
                ForEach(section.finished) { row in
                    SessionRowView(
                        row: row, detail: "\(row.harness) · \(row.model ?? "?")",
                        age: BenchSessionRow.age(sinceMs: row.lastMs, now: Date())
                    )
                    .opacity(0.6)
                }
            }
        }
    }
}

/// One chat in the list: its glyph and name, harness and model, the last message's first line and
/// its age, and a dot when the agent replied after he last opened it. Mail to him he has not read
/// takes the last message's place.
struct ChatRowView: View {
    @EnvironmentObject private var model: PocketModel
    @EnvironmentObject private var memory: ChatMemory
    let row: BenchSessionRow

    var body: some View {
        let attention = Attention(row)
        let preview = model.previews[row.id]
        let unread = preview?.isUnread(readThrough: memory.readThrough[row.id]) ?? false
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(attention.glyph).foregroundStyle(Palette.of(attention))
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(row.title).foregroundStyle(Palette.text).lineLimit(1)
                    Text("\(row.harness) · \(row.model ?? "?")").font(Mono.small)
                        .foregroundStyle(Palette.faint).lineLimit(1)
                    Spacer()
                    if unread { Text("●").font(Mono.small).foregroundStyle(Palette.finished) }
                    Text(age(preview)).font(Mono.small).foregroundStyle(Palette.dim)
                }
                if let mail = row.operatorMail, mail.unread > 0 {
                    Text("mailed you: \(mail.subject ?? "\(mail.unread) unread")")
                        .font(Mono.small).foregroundStyle(Palette.asking).lineLimit(1)
                } else {
                    Text(
                        MessageRow.markdown(
                            (preview?.mine == true ? "you: " : "") + (preview?.text ?? ""))
                    )
                    .font(Mono.small)
                    .foregroundStyle(unread ? Palette.text : Palette.dim)
                    .lineLimit(1)
                }
            }
        }
        .font(Mono.body)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func age(_ preview: ChatPreview?) -> String {
        BenchSessionRow.age(sinceMs: preview?.atMs ?? row.updatedAtMs, now: Date())
    }
}

/// One session: its glyph, its name, and a dim line under it.
struct SessionRowView: View {
    let row: BenchSessionRow
    let detail: String
    var age: String?

    var body: some View {
        let attention = Attention(row)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(attention.glyph).foregroundStyle(Palette.of(attention))
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(row.title).foregroundStyle(Palette.text).lineLimit(1)
                    Spacer()
                    Text(age ?? "›").foregroundStyle(age == nil ? Palette.faint : Palette.dim)
                }
                Text(detail).font(Mono.small).foregroundStyle(Palette.dim).lineLimit(1)
            }
        }
        .font(Mono.body)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// Why the last sessions poll failed for a workspace, when it did, in benchd's words.
struct Failure: View {
    @EnvironmentObject private var model: PocketModel

    var body: some View {
        if let failure = model.failure {
            Text(failure).font(Mono.small).foregroundStyle(Palette.asking).padding(.top, 10)
        }
    }
}

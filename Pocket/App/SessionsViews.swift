import HelmWire
import PocketKit
import SwiftUI

/// home: a search field, then each workspace as a section that collapses, the ones that need him
/// first. A section shows its running sessions, orchestrators (the sessions he started) first and
/// the rest dimmed under them, and its finished ones behind a disclosure.
struct HomeView: View {
    @EnvironmentObject private var model: PocketModel
    let talk: (String) -> Void
    @State private var query = ""
    /// The collapsed sections' paths, one per line: kept across launches.
    @AppStorage("collapsed") private var collapsedPaths = ""
    @State private var showingFinished: Set<String> = []

    private var collapsed: Set<String> {
        Set(collapsedPaths.split(separator: "\n").map(String.init))
    }

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
                            open: !collapsed.contains(section.path) || !query.isEmpty,
                            showingFinished: showingFinished.contains(section.path)
                                || !query.isEmpty,
                            toggle: { toggle(section.path) },
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

    private func toggle(_ path: String) {
        var paths = collapsed
        paths.formSymmetricDifference([path])
        collapsedPaths = paths.sorted().joined(separator: "\n")
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
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(open ? "▾" : "▸")
                Text(section.name.uppercased()).tracking(1)
                if section.needsHim { Text("●").foregroundStyle(Palette.asking) }
                Spacer()
                Text("\(section.running.count)")
            }
            .font(Mono.group).foregroundStyle(Palette.dim)
            .padding(.top, 10)
            .contentShape(Rectangle())
        }
        if open {
            if section.running.isEmpty {
                Text("nothing running").font(Mono.small).foregroundStyle(Palette.faint)
            }
            ForEach(section.running) { row in
                SessionRowView(row: row, detail: "\(row.harness) · \(row.model ?? "?")")
                    .opacity(row.isOrchestrator ? 1 : 0.6)
                    .onTapGesture { row.screen.map(talk) }
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

/// agents: every session on the bench once, by what it wants from the operator, with its age and
/// what it waits for.
struct AgentsView: View {
    @EnvironmentObject private var model: PocketModel
    let talk: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(PocketHome.agents(sessions: model.sessions)) { row in
                    SessionRowView(
                        row: row, detail: detail(row),
                        age: BenchSessionRow.age(sinceMs: row.lastMs, now: Date())
                    )
                    .opacity(row.screen == nil ? 0.6 : 1)
                    .onTapGesture { row.screen.map(talk) }
                }
                Failure()
            }
            .padding(.horizontal, 16)
        }
    }

    private func detail(_ row: BenchSessionRow) -> String {
        if let mail = row.operatorMail, mail.unread > 0 {
            return "mailed you: \(mail.subject ?? "\(mail.unread) unread")"
        }
        if case let .running(_, detail?) = row.state { return detail }
        return "\(row.harness) · \(row.model ?? "?")"
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

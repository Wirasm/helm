import HelmWire
import PocketKit
import SwiftUI

/// home: each workspace and the sessions on its bench Pocket can talk to.
struct HomeView: View {
    @EnvironmentObject private var model: PocketModel
    let talk: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(PocketHome.groups(workspaces: model.workspaces, sessions: model.sessions)) {
                    group in
                    Text(group.name.uppercased())
                        .font(Mono.group).tracking(1).foregroundStyle(Palette.dim)
                        .padding(.top, 10)
                    if group.rows.isEmpty {
                        Text("no agents").font(Mono.small).foregroundStyle(Palette.faint)
                    }
                    ForEach(group.rows) { row in
                        SessionRowView(row: row, detail: "\(row.harness) · \(row.model ?? "?")")
                            .onTapGesture { row.screen.map(talk) }
                    }
                }
                Failure()
            }
            .padding(.horizontal, 16)
        }
    }
}

/// agents: every session on the bench once, running first, with its age and what it waits for.
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

/// The last verb's failure, when there is one, in benchd's words.
struct Failure: View {
    @EnvironmentObject private var model: PocketModel

    var body: some View {
        if let failure = model.failure {
            Text(failure).font(Mono.small).foregroundStyle(Palette.asking).padding(.top, 10)
        }
    }
}

import SwiftUI

/// The observe column: every kild, and every agent inside it.
///
/// Built from small views rather than one large body, because each row type has a different
/// rule about what it may show and those rules are easier to keep honest when they are not
/// interleaved. A kild row reads git and attention; an agent row reads `ownership` and
/// `idle`; neither reads anything the engine did not state.
///
/// **Flat, with groups — not a tree.** rev 5 drew one tree rooted at the operator's
/// checkout, on the reasoning that a kild forked from another kild should render as its
/// child. The engine records no such edge: `KildIdentity` has no `parent`, and it cannot be
/// derived, since a forked kild's `base` names a branch rather than the kild it came from.
/// Drawing a hierarchy from a guess would be worse than drawing none — it would assert
/// structure the engine never claimed. Groups carry most of the value anyway, because the
/// thing that was actually missing was somewhere for abandoned kilds to live.
struct ObserveColumn: View {
    let groups: [KildGroup: [Kild]]
    let collisions: [Kild.ID: [Collision]]
    @Binding var selection: Kild.ID?
    /// Which kilds have their agents disclosed. Per-kild and persisted by the caller.
    @Binding var expanded: Set<Kild.ID>

    private var live: [Kild] { groups[.live] ?? [] }
    private var orphaned: [Kild] { groups[.orphaned] ?? [] }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(live) { kild in
                    KildRow(
                        kild: kild,
                        collisions: collisions[kild.id] ?? [],
                        isExpanded: expanded.contains(kild.id),
                        toggle: { toggle(kild.id) })
                    if expanded.contains(kild.id) {
                        // Explicitly non-selectable. `Agent.id` is a bare String, the same
                        // type as the selection binding, so an untagged agent row can end up
                        // participating in selection — putting a HANDLE where a kild id
                        // belongs. `selectedKild` then matches nothing, the dock silently
                        // vanishes, and the row keeps a selection highlight explaining none
                        // of it.
                        ForEach(kild.agents) { AgentRow(agent: $0) }
                            .tag(Optional<Kild.ID>.none)
                    }
                }
            } header: {
                SectionHeader(title: "observe", count: nil)
            }

            // Only when there are any. An empty "abandoned" heading is furniture.
            if !orphaned.isEmpty {
                Section {
                    ForEach(orphaned) { OrphanRow(kild: $0) }
                } header: {
                    SectionHeader(title: "no agents", count: orphaned.count)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func toggle(_ id: Kild.ID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

// MARK: - Rows

/// One kild. Shows its name, its attention, and the two things that make it actionable:
/// whether it collides with anything, and whether it is ready to land.
private struct KildRow: View {
    let kild: Kild
    let collisions: [Collision]
    let isExpanded: Bool
    let toggle: () -> Void

    /// Attention is inherited from the agents inside.
    ///
    /// This must hold whether or not the fold is open — a collapsed kild that hides a
    /// waiting agent is precisely the failure the count exists to prevent. Reading the
    /// agents directly rather than a cached flag is what guarantees it.
    private var isWaiting: Bool {
        kild.agents.contains { $0.isIdle && !$0.isStopped }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(kild.agents.isEmpty)
            .opacity(kild.agents.isEmpty ? 0 : 1)

            Text(kild.name).lineLimit(1).truncationMode(.middle)

            Spacer(minLength: 4)

            if !collisions.isEmpty {
                CollisionBadge(count: collisions.count)
            }
            if isWaiting {
                AttentionDot(waiting: true)
            }
        }
        .tag(kild.id)
    }
}

/// One agent inside a kild.
private struct AgentRow: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 6) {
            Text("@\(agent.handle)")
                .font(.system(size: 11.5))
                // Italic marks an attached agent — the one place styling reads a field's
                // value. Justified because it marks how much is *observable*, not a role:
                // kild never spawned it and genuinely cannot see inside it.
                .italic(agent.ownership == .attached)
                .foregroundStyle(agent.isStopped ? .tertiary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if agent.isStopped {
                // Stopped is over, not resting — it is not waiting on anyone, so it gets a
                // word rather than a dot and never counts toward attention.
                Text("stopped").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else if agent.isIdle {
                AttentionDot(waiting: true)
            }
        }
        .padding(.leading, 16)
    }
}

/// A kild that exists only as a worktree on disk, its engine record gone.
///
/// Shown deliberately plainly: there is nothing to observe here — no agents, no log, no git
/// — so a row that looked like a live kild would be promising something it cannot deliver.
/// What it offers is the one thing it can: being visible enough to dispose of.
private struct OrphanRow: View {
    let kild: Kild

    var body: some View {
        HStack(spacing: 6) {
            Text(kild.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
        }
        .tag(kild.id)
    }
}

// MARK: - Chrome

private struct SectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.3)
            if let count {
                Text("· \(count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            }
        }
        .foregroundStyle(.tertiary)
    }
}

/// The attention signal, wherever it appears.
///
/// One field, one shape, one colour — the sidebar row, the agent row and the terminal tab
/// all render this, so attention looks the same whichever surface you are on.
struct AttentionDot: View {
    let waiting: Bool

    var body: some View {
        Circle()
            .fill(waiting ? Color.accentColor : Color.secondary)
            .frame(width: 6, height: 6)
            .accessibilityLabel(waiting ? "waiting on you" : "working")
    }
}

/// How many other kilds are touching the same files.
///
/// Derived, not served — helm intersects `changedFiles` across live kilds. Rendered as a
/// count rather than a list because the detail belongs on the land gate, where it is
/// actionable; here it only needs to say "there is something to know".
struct CollisionBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
            Text("\(count)").font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(.orange)
        .accessibilityLabel("collides with \(count) other kild\(count == 1 ? "" : "s")")
    }
}

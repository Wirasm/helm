import SwiftUI

/// The right dock: everything the engine knows about the selected kild.
///
/// Every row is a field or a labelled derivation. Where a value has not arrived — the cheap
/// listing carries no git — the row is **absent**, never rendered as a zero or a dash. The
/// difference between "0 ahead" and "not measured yet" is the whole reason the listing was
/// split in two, and collapsing it here would put the cost back in the UI after the engine
/// went to the trouble of removing it.
struct KildDock: View {
    let kild: Kild
    let collisions: [Collision]
    /// Set when the costly half failed, so a missing git block can say why rather than
    /// looking like it is still loading.
    let statusError: String?
    let openCollision: (Kild.ID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                identity

                if let git = kild.git {
                    if git.isTrustworthy {
                        position(git)
                        changedFiles(git)
                    } else {
                        // A failed probe returns safe defaults that read as a clean tree.
                        // Showing them would be showing fiction, so the numbers are withheld
                        // and the reason shown instead.
                        Row(label: "git", value: "could not be read")
                        Text(git.error ?? "unknown failure")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                } else if let statusError {
                    Row(label: "git", value: "stale")
                    Text(statusError).font(.system(size: 10)).foregroundStyle(.orange)
                }

                if !collisions.isEmpty { collisionSection }
                if let totals = kild.totals { cost(totals) }
                if kild.isOrphan { orphanNote }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: sections

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(kild.name).font(.system(size: 12, weight: .semibold))
            if let worktree = kild.worktree {
                Text("⑂ kild/\(worktree)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tint)
            }
            Text(kild.cwd)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private func position(_ git: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Row(label: "branch", value: git.branch ?? "detached")
            Row(label: "vs \(git.base)", value: "↑\(git.ahead) ↓\(git.behind)")
            // `uncommittedFiles` is a count, not a list — named as the wire names it.
            Row(
                label: "tree",
                value: git.dirty ? "\(git.uncommittedFiles) uncommitted" : "clean")
        }
    }

    private func changedFiles(_ git: GitStatus) -> some View {
        Group {
            if !git.changedFiles.isEmpty {
                SectionLabel("files · \(git.changedFiles.count)")
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(git.changedFiles.prefix(12), id: \.self) { file in
                        Text(file)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if git.changedFiles.count > 12 {
                        Text("+ \(git.changedFiles.count - 12) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Derived, and labelled as such — helm intersected `changedFiles` across live kilds.
    /// The other kild is a link because the fix is over there, not here.
    private var collisionSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                SectionLabel("collides with")
                Text("DERIVED")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            ForEach(collisions, id: \.other) { collision in
                Button {
                    openCollision(collision.other)
                } label: {
                    HStack(spacing: 4) {
                        Text(collision.otherName).underline()
                        Text("· \(collision.files.count)")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cost(_ totals: CostTotals) -> some View {
        Row(
            label: "cost",
            value: String(format: "$%.2f · %dk tok", totals.cost, totals.tokens / 1000))
    }

    /// An orphan is a tree whose engine record is gone. It has no agents, no log and no
    /// base, so the dock says what it *is* rather than showing empty rows for what it lacks.
    private var orphanNote: some View {
        Text(
            "no engine record — enumerated from git. It has no agents and no log, "
                + "and is addressed by its worktree name."
        )
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Chrome

private struct Row: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Text(value)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(.tertiary)
            .padding(.top, 3)
    }
}

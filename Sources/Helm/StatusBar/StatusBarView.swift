import Inject
import SwiftUI

/// The bar along the bottom: what you can press, and where you are.
///
/// **Two jobs, and both are reading.** On the left, the keys — because helm binds a few
/// dozen and mentioned none of them anywhere in the window, which is a discoverability
/// score of zero and the reason an operator could not open a second pane on their first
/// day. On the right, the three facts helm already knows: which workspace, which branch,
/// and whether an agent in it has stopped and wants them.
///
/// **No decisions.** Which hints exist is `KeyHints`, which is pure and tested; what the
/// facts are is `StatusSummary`, likewise; whether the terminal holds the keyboard is
/// `TerminalFocusWatch`. This file arranges them and picks type sizes.
///
/// Quiet on purpose. Two type weights below the terminal's, on the same chrome plane as the
/// strips, nothing that moves, nothing that pops. It is a thing you look at when you want
/// it and never notice otherwise — chrome recedes, the terminal is the centre.
struct StatusBarView: View {
    @ObserveInjection private var inject
    @ObservedObject var model: WorkspaceModel
    /// For benchd's badge and the drawer capsules, both drawn from benchd's document.
    let workbench: WorkbenchModel
    /// The operator's just runs that failed or did not start.
    let justRuns: JustRuns
    /// Already polled on the workspace bar's behalf; observing it here costs nothing new.
    @ObservedObject private var board = BoardModel.shared
    /// A `@StateObject` because the subscription's lifetime should be this bar's, not a
    /// render's — the mistake `AGENTS.md` records twice over.
    @StateObject private var focus = TerminalFocusWatch()
    /// Same reasoning, and the same lifetime: a badge nobody can see is a poll nobody needs.
    @StateObject private var builds = BuildUpdateModel()
    /// The keys in force, and why the operator's keymap file was refused, if it was.
    @ObservedObject private var keymap = Keymap.shared

    var body: some View {
        HStack(spacing: 12) {
            hints
            stats
        }
        .task { await builds.poll() }
        .font(.system(size: 10.5))
        // Sets the base every `.secondary` inside resolves against, so the whole bar reads
        // out of the palette rather than out of the system's label colours.
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ChromeBackground())
        .enableInjection()
    }

    /// Scrolls rather than truncates: on a narrow window the tail of the map is still
    /// reachable, and on the operator's own screens it never comes up. Indicators hidden —
    /// a scrollbar in a status bar is louder than the thing it is scrolling.
    private var hints: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 13) {
                ForEach(KeyHints.visible(terminalFocused: focus.terminalFocused, in: keymap.table))
                {
                    hint in
                    HStack(spacing: 4) {
                        Text(hint.keys).foregroundStyle(Color.textMuted)
                        Text(hint.label).foregroundStyle(Color.textFaint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Right-hand side, and it yields nothing: `layoutPriority` keeps the branch name whole
    /// while the hints give up width, because the hints can scroll and a truncated branch
    /// is just wrong.
    @ViewBuilder
    private var stats: some View {
        let summary = StatusSummary.of(
            workspace: model.selectedWorkspace,
            branches: model.branches,
            presence: board.presence
        )
        HStack(spacing: 6) {
            JustCapsules(runs: justRuns) { log in
                workbench.send(.paneOpen(surface: .canvas(path: log)), by: .operatorGesture)
            }
            DrawerCapsules(model: workbench)
            BenchStatusBadge(client: workbench.client, workbench: workbench)
            isolationBadge
            keymapBadge
            buildBadge
            if let label = summary.agentLabel {
                AgentDot(presence: summary.agents)
                Text(label).foregroundStyle(Color.textMuted)
            }
            if let workspace = summary.workspace {
                Text(workspace).foregroundStyle(Color.textMuted)
            }
            if let branch = summary.branch {
                Text(branch).foregroundStyle(Color.textFaint).lineLimit(1)
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }

    /// Which defaults domain this instance is writing, when it is not the operator's (#86).
    ///
    /// **The loudest thing in the bar, and deliberately so.** Everything else here recedes;
    /// this one exists because a test instance mistaken for the real one is how #86 nearly
    /// cost the operator their workspaces. It is `accent` on a filled capsule against a bar
    /// of muted greys, and it names the suite rather than saying "isolated" — the name is
    /// what `defaults read` needs.
    ///
    /// Absent entirely with the variable unset, which is every normal launch.
    @ViewBuilder
    private var isolationBadge: some View {
        if DefaultsDomain.isIsolated {
            Text(DefaultsDomain.activeDomain)
                .foregroundStyle(Color.surface)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accent, in: Capsule())
                .help("Isolated instance — persisting to the \(DefaultsDomain.activeDomain) suite")
        }
    }

    /// The operator's keymap file was refused, and the keys are still the last good table.
    ///
    /// Says the line and the reason, because a refusal nobody sees is the silent fallback the
    /// keymap must never be: the operator saved a key, pressed it, and nothing happened. Clicking
    /// it opens the file as a canvas beside the bench. Absent while the file is good or missing.
    @ViewBuilder
    private var keymapBadge: some View {
        if let problem = keymap.problem, let file = keymap.file {
            Button {
                workbench.send(.paneOpen(surface: .canvas(path: file.path)), by: .operatorGesture)
            } label: {
                Text(problem.sentence)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
                    .foregroundStyle(Color.surface)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.attention, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(
                "\(file.path) was not loaded, so the last good keys are in force. "
                    + "\(problem.sentence). Click to open it.")
        }
    }

    /// A newer build is on disk, and pressing this takes it.
    ///
    /// **The one thing in this bar that is a control rather than a reading**, which is why it
    /// gets a capsule and a colour while everything around it is muted grey text. It is also
    /// the only shape this feature was allowed to take: the operator asked not to be
    /// interrupted by a dialog, and helm's own rule since #125 is *appear, don't seize* — a
    /// modal over a terminal someone is typing into is the wrong-window click arriving through
    /// a supported API.
    ///
    /// `attention` rather than `accent`, so it does not read as a second isolation badge —
    /// that one is the loudest thing here on purpose, and this must not compete with it.
    ///
    /// Absent entirely when there is nothing waiting, which is almost always.
    @ViewBuilder
    private var buildBadge: some View {
        if let stamp = builds.update.waiting {
            Button {
                builds.relaunch()
            } label: {
                Text("new build")
                    .foregroundStyle(Color.surface)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.attention, in: Capsule())
            }
            .buttonStyle(.plain)
            // Says what it will cost before it costs it: this quits helm, and every pane goes
            // with it. The sha is what tells the operator which build they are being offered.
            .help(
                "Build \(stamp.sha) is ready — click to quit helm, install it and reopen. "
                    + "Every terminal and its agent closes.")
        }
    }
}

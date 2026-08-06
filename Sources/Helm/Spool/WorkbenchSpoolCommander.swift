import Foundation
import HelmWire

/// The driving edge: carries out a command an agent asked for, and reports what it did (#269).
///
/// It lives beside `WorkbenchSpoolSpawner` and `WorkbenchSpoolCloser` for the same reason both
/// of those do — it is the spool's adapter onto the bench, not a bench feature (`AGENTS.md`).
///
/// **It decides nothing about *whether*.** `SpoolCommandPolicy` (`HelmWire`) has already refused
/// every command an agent may not send, and this type is only reached with one it may. What is
/// genuinely here is *how*: which of helm's two shapes an allowed command routes to.
///
/// **Three of the four route to a non-seizing twin, and the fourth needs none.** helm has drawn
/// that distinction since #125 and named both halves — `Workbench.insert` is the operator
/// asking, `Workbench.offer` is an agent offering, and they differ in the line that assigns
/// `focusedSlot`. So:
///
/// - `newTerminal` → `WorkbenchModel.spawnTerminal()`, which is `newTerminal()`'s offering twin
///   and predates this ticket entirely — it is what the spool's own `spawn` kind already uses.
/// - `splitRight`/`splitDown` → `offerSplitRight()`/`offerSplitDown()`, the twins added for
///   #269 on top of `Workbench.splitRight(offering:)`.
/// - `toggleRail` → posted as the real `HelmCommand`, because there is no seizing to avoid: it
///   shows or hides chrome beside the bench and touches no pane. Posting rather than calling
///   `ArchonRailModel.toggleVisibility()` directly would be a second route to the same state
///   with the model's own subscription sitting unused, so the model is held and called — see
///   `rail` below.
///
/// **`focusedPaneBefore`/`After` are read here, either side of the mutation**, and that is the
/// point of measuring them at this layer: this is the only place that can see the live bench,
/// and a promise the caller can check beats a promise a header makes.
@MainActor
final class WorkbenchSpoolCommander: SpoolCommanding {
    private let workbench: WorkbenchModel
    /// Held rather than reached for through a notification, so `toggleRail` has the same
    /// synchronous "it happened" guarantee as the other three. `HelmCommand.publisher` hops to
    /// the main queue before `ArchonRailModel` sees it (`ArchonRailModel.init`), so a posted
    /// command would still be in flight when the result was written — and a result that says
    /// `ran` about something that has not run yet is the silence this ladder exists to remove.
    private let rail: ArchonRailModel

    init(workbench: WorkbenchModel, rail: ArchonRailModel) {
        self.workbench = workbench
        self.rail = rail
    }

    func run(_ command: HelmCommandName) -> Result<CommandReport, SpoolRefusal> {
        let before = workbench.bench?.focusedPane?.id
        let created: UUID?

        switch command {
        case .newTerminal:
            guard let session = workbench.spawnTerminal() else { return .failure(noBench) }
            created = session.id
        case .splitRight:
            guard let session = workbench.offerSplitRight() else { return .failure(noBench) }
            created = session.id
        case .splitDown:
            guard let session = workbench.offerSplitDown() else { return .failure(noBench) }
            created = session.id
        case .toggleRail:
            rail.toggleVisibility()
            created = nil

        // **Named rather than defaulted, and unreachable rather than merely unhandled.**
        // `SpoolPolicy.accept` runs `SpoolCommandPolicy.verdict` before an
        // `AcceptedCommandRequest` can exist, so nothing below can arrive here through the
        // spool. Listing them is what makes a *newly allowed* command fail to compile here
        // instead of silently doing nothing: flip a verdict to `.allowed` in `HelmWire` and
        // this switch is what forces a route to be chosen for it.
        case .selectTerminal, .openArtifact, .openCanvasFile, .pushCanvasFile, .openCanvasURL,
            .openWorkspace, .adjustFontSize, .jumpToPrompt, .selectWorkspace, .cycleWorkspace,
            .toggleChat, .closePane, .moveFocus, .composeText:
            return .failure(
                SpoolRefusal(
                    "\(command.rawValue) is allowed by SpoolCommandPolicy but helm has no route "
                        + "for it. That is a helm defect: the policy and "
                        + "WorkbenchSpoolCommander disagree about what may be sent."))
        }

        let after = workbench.bench
        // Bound rather than written inline: `after?.focusedPane?.id.map(…)` keeps the optional
        // chain going and calls `map` on the `UUID` itself, which does not compile.
        let focusedAfter = after?.focusedPane?.id
        return .success(
            CommandReport(
                command: command,
                paneCreated: created.map(TerminalID.init),
                focusedPaneBefore: before.map(TerminalID.init),
                focusedPaneAfter: focusedAfter.map(TerminalID.init),
                columns: after?.columns.count ?? 0,
                panes: after?.panes.count ?? 0))
    }

    /// The one thing that can actually go wrong here, and it is the same condition every
    /// bench-touching method on `WorkbenchModel` guards with `guard let workspacePath, var
    /// bench` — helm running with nothing open.
    private var noBench: SpoolRefusal {
        SpoolRefusal(
            "helm has no workspace open, so there is no bench to run a command on. Open one, or "
                + "send a spawn — its cwd is what opens a workspace.")
    }
}

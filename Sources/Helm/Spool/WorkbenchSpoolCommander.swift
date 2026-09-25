import Foundation
import HelmWire

/// The driving edge: carries out a command an agent asked for, and reports what it did (#269).
///
/// It lives beside `WorkbenchSpoolSpawner` and `WorkbenchSpoolPanes` for the same reason both
/// of those do — it is the spool's adapter onto the bench, not a bench feature (`AGENTS.md`).
///
/// **It decides nothing about *whether*.** `SpoolCommandPolicy` (`HelmWire`) has already refused
/// every command an agent may not send, and this type is only reached with one it may. What is
/// genuinely here is *how*: which of helm's two shapes an allowed command routes to.
///
/// **Four of the five are bench verbs, sent as an agent**, so the sink leaves the keyboard where
/// the operator put it — the same rule every agent's verb gets (`LocalSink`, and benchd's
/// `Focus`). `newTerminal` is `pane/open` of a terminal, the splits are `pane/split`, and
/// `openBrowser` is `pane/open` of the browser (#350).
///
/// `toggleRail` is the fifth and touches no pane: it shows or hides chrome beside the bench, so
/// there is no verb for it and no seizing to avoid. The rail's model is held and called.
///
/// **`focusedPaneBefore`/`After` are read here, either side of the mutation**, and that is the
/// point of measuring them at this layer: this is the only place that can see the live bench,
/// and a promise the caller can check beats a promise a header makes.
@MainActor
final class WorkbenchSpoolCommander: SpoolCommanding {
    private let workbench: WorkbenchModel
    /// Called directly, so `toggleRail` has happened by the time the result is written — a
    /// result that says `ran` about something that has not run yet is the silence this ladder
    /// exists to remove.
    private let rail: ArchonRailModel

    init(workbench: WorkbenchModel, rail: ArchonRailModel) {
        self.workbench = workbench
        self.rail = rail
    }

    func run(_ command: HelmCommandName) -> Result<CommandReport, SpoolRefusal> {
        let before = workbench.bench?.focusedPane?.id

        let verb: BenchVerb
        switch command {
        case .newTerminal: verb = .paneOpen(surface: .terminal(agent: nil))
        case .splitRight: verb = .paneSplit(direction: .right)
        case .splitDown: verb = .paneSplit(direction: .down)
        case .openBrowser: verb = .paneOpen(surface: .browser)
        case .toggleRail:
            rail.toggleVisibility()
            return .success(report(command, before: before, created: nil))

        // **Named rather than defaulted, and unreachable rather than merely unhandled.**
        // `SpoolPolicy.accept` runs `SpoolCommandPolicy.verdict` before an
        // `AcceptedCommandRequest` can exist, so nothing below can arrive here through the
        // spool. Listing them is what makes a *newly allowed* command fail to compile here
        // instead of silently doing nothing: flip a verdict to `.allowed` in `HelmWire` and
        // this switch is what forces a route to be chosen for it.
        case .selectTerminal, .openArtifact, .openCanvasFile, .pushCanvasFile,
            .openWorkspace, .adjustFontSize, .jumpToPrompt, .selectWorkspace, .cycleWorkspace,
            .closePane, .moveFocus, .movePane, .newNote:
            return .failure(
                SpoolRefusal(
                    "\(command.rawValue) is allowed by SpoolCommandPolicy but helm has no route "
                        + "for it. That is a helm defect: the policy and "
                        + "WorkbenchSpoolCommander disagree about what may be sent."))
        }

        guard let created = workbench.send(verb, by: .agent()) else { return .failure(noBench) }
        return .success(report(command, before: before, created: created))
    }

    private func report(_ command: HelmCommandName, before: UUID?, created: UUID?) -> CommandReport
    {
        let after = workbench.bench
        // Bound rather than written inline: `after?.focusedPane?.id.map(…)` keeps the optional
        // chain going and calls `map` on the `UUID` itself, which does not compile.
        let focusedAfter = after?.focusedPane?.id
        return CommandReport(
            command: command,
            paneCreated: created.map(TerminalID.init),
            focusedPaneBefore: before.map(TerminalID.init),
            focusedPaneAfter: focusedAfter.map(TerminalID.init),
            columns: after?.columns.count ?? 0,
            panes: after?.panes.count ?? 0)
    }

    /// Why there was no bench to act on — and there are now **two** answers, which is why this
    /// is not one sentence any more.
    ///
    /// `guard let workspacePath, var bench` is the condition every bench-touching method on
    /// `WorkbenchModel` shares, and before #85 it meant one thing: helm running with nothing
    /// open. It now also means a workspace **is** mounted and is waiting on the operator to say
    /// whether to restore its saved bench. Telling those apart is not tidiness: measured live
    /// against a real restart, an agent sending `newTerminal` at that moment was told *"helm has
    /// no workspace open… open one"* about a workspace that was open, and the only thing it
    /// could do with that advice was ask helm to open it again.
    ///
    /// The pending answer names the route that actually works, which is the same one the spawn
    /// path takes: a spool spawn's `cwd` mounts without asking (`WorkbenchSpoolSpawner
    /// .openTerminal`), so it resolves the question rather than waiting behind it.
    private var noBench: SpoolRefusal {
        guard let offer = workbench.restoreOffer else {
            return SpoolRefusal(
                "helm has no workspace open, so there is no bench to run a command on. Open "
                    + "one, or send a spawn — its cwd is what opens a workspace.")
        }
        return SpoolRefusal(
            "helm is asking the operator whether to restore \(offer.paneCount) saved pane(s) in "
                + "this workspace, so there is no bench yet. A bench command carries no address "
                + "and cannot answer that for them. Send a spawn instead — its cwd mounts the "
                + "workspace without asking — or wait until they answer.")
    }
}

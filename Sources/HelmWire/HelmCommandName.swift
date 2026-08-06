import Foundation

/// A helm command's stable identity, without its payload.
///
/// **This was `HelmCommand.Name`, nested inside `Helm` (#219), and it moved here for #269.**
/// It is the same enumeration doing the same job — its own header in `HelmCommand.swift` called
/// it *"not a convenience for the status bar — the command's public name"* and said the names
/// are *"what a config writes"* — and #269 is the ticket where something outside the process
/// started writing them. `SpoolCommandPolicy` (`Spool/SpoolRequest.swift`) decides per command
/// whether an agent may send it, `CommandRequest` carries one across the spool, and
/// `SpoolResult.command` reports which one ran. All three live in `HelmWire`, which depends on
/// nothing in `Helm`, so the identity had to be reachable from here.
///
/// **What did not move is `HelmCommand` itself, and that is the seam decision #269 asks for.**
/// `HelmCommand`'s payloads are `Workbench.Direction`, `CanvasPushRequest`, `Pane.ID`,
/// `FontSizeStep` and `URL` — the live app's vocabulary. Dragging them into `HelmWire` to
/// expose four commands would invert the dependency this target exists to keep one-way. So the
/// *identity* is shared and the *payloads* stay where they are, and `Helm` keeps
/// `HelmCommand.Name` as a typealias onto this type so no call site there had to change.
///
/// **The payloads staying behind costs nothing today, and that is a consequence rather than a
/// coincidence.** Every command `SpoolCommandPolicy` allows is payload-free, because every
/// command that carries a payload carries it to *address* something — an index, a direction, a
/// delta, a pane — and the thing each of them addresses is the operator's focus point, which is
/// exactly what the focus rule refuses. So for now the name is the whole payload. If a
/// payload-carrying command is ever allowed, its payload joins this file rather than being
/// restated on the wire: one definition, in the target both sides can reach.
///
/// `String`-backed and `CaseIterable` on purpose, both load-bearing beyond #219's reasons: the
/// raw values are what `tools/helm-command.swift` takes on its command line, and `allCases` is
/// what lets `SpoolCommandPolicy` be *total* — a nineteenth command cannot be added without a
/// verdict, because the switch that gives one stops compiling.
package enum HelmCommandName: String, CaseIterable, Codable, Sendable {
    case newTerminal, selectTerminal, openArtifact, openCanvasFile, pushCanvasFile
    case openCanvasURL, openWorkspace, adjustFontSize, jumpToPrompt, selectWorkspace
    case cycleWorkspace, toggleChat, splitRight, splitDown, closePane, moveFocus
    case composeText, toggleRail
}

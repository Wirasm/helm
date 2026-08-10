import HelmWire
import XCTest

@testable import Helm

/// Which of helm's own commands an agent may send (#269) — the decision, pinned.
///
/// **This file is the allowlist's regression test, not its documentation.** The argument lives
/// in `SpoolCommandPolicy`'s header; what is here is the part a future change can break
/// silently. The rule it holds is one sentence — *rearranging the bench is fine, taking focus is
/// not* — and every assertion below is a reading of it.
///
/// Nothing here needs a bench, a surface or a pty: `SpoolCommandPolicy` is a pure function of a
/// command's name, which is the same trade `SpoolClosePolicy` makes and for the same reason.
final class SpoolCommandPolicyTests: XCTestCase {

    // MARK: - The decision

    /// **The allowlist itself, written out.** A change to it has to change this line, which is
    /// the point: an allowlist that can widen without a diff anyone reads is not a decision.
    func testTheAllowlistIsExactlyTheFourCommandsThatDoNotTakeTheKeyboard() {
        XCTAssertEqual(
            SpoolCommandPolicy.allowed, [.newTerminal, .splitRight, .splitDown, .toggleRail],
            "these four grow the bench and leave the operator's keyboard where it is. Widening "
                + "this set is a decision about the operator's focus — read "
                + "SpoolCommandPolicy's header before changing it")
    }

    /// Every command that moves `focusedSlot`, measured against what `Workbench` actually does
    /// rather than against how the command reads.
    func testEveryCommandThatMovesTheOperatorsKeyboardIsRefused() {
        for command in [
            HelmCommandName.moveFocus, .selectTerminal, .selectWorkspace, .cycleWorkspace,
            .openCanvasFile, .openCanvasURL,
        ] {
            XCTAssertNotEqual(
                SpoolCommandPolicy.verdict(for: command), .allowed,
                "\(command.rawValue) moves the operator's keyboard — Workbench.select, "
                    + "Workbench.insert and a workspace switch all assign focusedSlot")
        }
    }

    /// The other half of the rule: a command with no address acts on whichever pane the
    /// operator is in, so there is nothing for a policy to check.
    func testEveryUnaddressedCommandThatActsOnTheFocusedPaneIsRefused() {
        for command in [
            HelmCommandName.closePane, .adjustFontSize, .jumpToPrompt, .toggleChat, .composeText,
            // #287's half of it, and the one worth reading twice: `Workbench.move` *is*
            // addressed — it names the pane it moves — but `HelmCommand.movePane` carries only a
            // direction and applies it to the focused pane. The operation is allowable and the
            // command is not, which is a refusal about the wire rather than about the bench.
            .movePane,
        ] {
            XCTAssertNotEqual(
                SpoolCommandPolicy.verdict(for: command), .allowed,
                "\(command.rawValue) acts on the focused pane and carries no pane of its own, "
                    + "so from a request file it acts on the operator's")
        }
    }

    /// **#289's verdict, and the clearest case on the list.** Starting a note creates a file,
    /// inserts a pane, selects it, focuses its slot and puts the cursor in an editor — a
    /// keystroke destination, not merely a layout change. There is no non-seizing twin to route
    /// to, because a note nobody is sitting in front of is a file, and writing a file is
    /// something an agent already does without asking helm.
    func testStartingANoteIsRefusedAndSaysWhereAnAgentsOwnWritingGoesInstead() {
        guard case .refused(let reason) = SpoolCommandPolicy.verdict(for: .newNote) else {
            return XCTFail(
                "newNote is the operator asking for somewhere to write — it takes the keyboard "
                    + "by construction, which is the whole of the focus rule")
        }
        XCTAssertTrue(
            reason.contains("push.sh"),
            "the refusal has to name the offering route an agent actually has; got \"\(reason)\"")
        XCTAssertTrue(
            reason.contains("notes/"),
            "and it has to say that the notes directory is the operator's, which is the rule "
                + "that keeps #289's unanswered half unreachable; got \"\(reason)\"")
    }

    // MARK: - Refusals say something

    /// **A refusal that does not say why is the silence this whole ladder exists to remove.**
    func testEveryRefusalCarriesAReason() {
        for command in HelmCommandName.allCases {
            guard case .refused(let reason) = SpoolCommandPolicy.verdict(for: command) else {
                continue
            }
            XCTAssertFalse(
                reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(command.rawValue) is refused with an empty reason")
            XCTAssertTrue(
                reason.contains(command.rawValue),
                "\(command.rawValue)'s refusal should name the command it is about, so a caller "
                    + "reading only `reason` knows which request it answered; got \"\(reason)\"")
        }
    }

    /// #176's rule extended rather than reinvented: where an addressed route already exists,
    /// the refusal names it instead of leaving the caller to guess.
    func testTheRefusalsNameTheAddressedRouteWhereThereIsOne() {
        guard case .refused(let closePane) = SpoolCommandPolicy.verdict(for: .closePane) else {
            return XCTFail("closePane must be refused — it closes the operator's focused pane")
        }
        XCTAssertTrue(
            closePane.contains("helm-close"),
            "closePane's refusal must point at helm-close, which names a pane and refuses the "
                + "one holding the keyboard; got \"\(closePane)\"")

        // #284 gave the other direction an addressed route too, so `selectTerminal`'s refusal
        // stopped being a dead end — it said *"to make a pane of your own current, there is
        // nothing yet"* and there now is.
        guard case .refused(let selectTerminal) = SpoolCommandPolicy.verdict(for: .selectTerminal)
        else {
            return XCTFail("selectTerminal must be refused — it carries an index, not a pane")
        }
        XCTAssertTrue(
            selectTerminal.contains("helm-select"),
            "selectTerminal's refusal must point at helm-select, which names a pane and refuses "
                + "one in the operator's own slot; got \"\(selectTerminal)\"")

        guard case .refused(let push) = SpoolCommandPolicy.verdict(for: .openCanvasFile) else {
            return XCTFail("openCanvasFile must be refused — Workbench.insert selects and focuses")
        }
        XCTAssertTrue(
            push.contains("push.sh"),
            "openCanvasFile's refusal must point at push.sh, the offering route; got \"\(push)\"")

        guard case .refused(let workspace) = SpoolCommandPolicy.verdict(for: .openWorkspace) else {
            return XCTFail("openWorkspace must be refused — it raises a folder panel")
        }
        XCTAssertTrue(
            workspace.contains("helm-spool"),
            "openWorkspace's refusal must point at helm-spool — a spawn's cwd is the workspace "
                + "helm opens for it, which is the headless route to the same outcome; got "
                + "\"\(workspace)\"")
    }

    /// **Every route a refusal names has to be a real one.** A message that sends a caller to a
    /// script that does not exist is worse than one that says nothing: it costs them a search
    /// before they learn there is no answer. Checked against the repository, not against this
    /// file's memory of it.
    func testEveryRouteARefusalNamesIsAScriptThatExists() {
        let tools = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Spool/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("tools")
        let routes = [
            "helm-close": "helm-close.swift", "helm-spool": "helm-spool.swift",
            "helm-select": "helm-select.swift",
        ]
        var named: Set<String> = []
        for command in HelmCommandName.allCases {
            guard case .refused(let reason) = SpoolCommandPolicy.verdict(for: command) else {
                continue
            }
            for (route, script) in routes where reason.contains(route) {
                named.insert(route)
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: tools.appendingPathComponent(script).path),
                    "\(command.rawValue)'s refusal sends the caller to \(route), and "
                        + "tools/\(script) is not there")
            }
        }
        XCTAssertEqual(
            named, Set(routes.keys),
            "every route should be reachable from some refusal — if one stopped being named, "
                + "the headers claiming it is are now wrong too")
    }

    // MARK: - Through the real gate

    /// The policy is only worth anything if `SpoolPolicy.accept` actually consults it, which is
    /// the seam a refactor could quietly cut.
    func testSpoolPolicyAcceptsAnAllowedCommandAndRefusesADisallowedOne() {
        guard
            case .success(.command(let accepted)) = accept(
                CommandRequest(id: "ok", command: "splitRight"))
        else {
            return XCTFail("SpoolPolicy did not accept splitRight, which is on the allowlist")
        }
        XCTAssertEqual(accepted.command, .splitRight, "and it parsed the name once, here")

        guard case .failure(let refusal) = accept(CommandRequest(id: "no", command: "moveFocus"))
        else {
            return XCTFail("SpoolPolicy accepted moveFocus, which is the focus rule itself")
        }
        XCTAssertTrue(
            refusal.reason.contains("moveFocus"),
            "the refusal must name the command; got \"\(refusal.reason)\"")
    }

    /// **Two refusals, not one.** *"That is not a command helm has"* is a typo a caller can fix;
    /// *"that is a command helm will not take from an agent"* is a standing decision it cannot.
    /// A single message for both sends someone hunting for a spelling mistake in a name they
    /// spelled correctly.
    func testAnUnknownNameIsARefusalOfItsOwnAndListsTheNamesHelmHas() {
        guard case .failure(let refusal) = accept(CommandRequest(id: "x", command: "splitSideways"))
        else {
            return XCTFail("SpoolPolicy accepted a command name helm does not have")
        }
        XCTAssertTrue(
            refusal.reason.contains("is not a helm command"),
            "an unknown name must say so rather than reading as a policy decision; got "
                + "\"\(refusal.reason)\"")
        XCTAssertTrue(
            refusal.reason.contains("moveFocus") && refusal.reason.contains("splitRight"),
            "…and must list the names helm does have, refused ones included, so a caller can "
                + "tell a typo from a policy; got \"\(refusal.reason)\"")
    }

    /// Whitespace either side of a name is a shell's doing, not a caller's mistake.
    func testANameIsTrimmedBeforeItIsJudged() {
        guard
            case .success(.command(let accepted)) = accept(
                CommandRequest(id: "ok", command: "  toggleRail\n"))
        else {
            return XCTFail("a name with surrounding whitespace was not accepted")
        }
        XCTAssertEqual(accepted.command, .toggleRail)
    }

    // MARK: - Controls

    /// **A control, and named as one: it passes whatever the allowlist says.** It exists to
    /// catch the *other* failure — a change that narrows `HelmCommandName` itself, or that
    /// leaves the wire's `kinds` list saying there are three. Neither is what this ticket
    /// changes, and both would break every caller.
    func testTheEnvelopeStillAdvertisesEveryKindHelmKnows() {
        XCTAssertEqual(
            SpoolRequest.kinds, ["spawn", "capture", "close", "command", "select", "name"],
            "the refusal for an unknown kind lists these, so an older helm's answer and a newer "
                + "one's have to differ in exactly this line")
        XCTAssertEqual(
            HelmCommandName.allCases.count, 20,
            "helm has twenty commands — eighteen from #219, plus movePane (#287) and newNote "
                + "(#289). If that number changed, SpoolCommandPolicy's "
                + "switch already forced a verdict for the new one — this only records that it "
                + "was a deliberate change rather than a merge artefact")
    }

    private func accept(_ request: CommandRequest) -> Result<SpoolWork, SpoolRefusal> {
        SpoolPolicy.accept(
            .command(request), captures: URL(fileURLWithPath: "/tmp"), isDirectory: { _ in true })
    }
}

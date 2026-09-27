import AppKit
import XCTest

@testable import Helm

/// The key pop-up (#499): when it shows, and what it lists.
final class KeyPopupTests: XCTestCase {
    // MARK: - When it shows

    private func run(_ events: [ManageHold.Event]) -> ManageHold.Phase {
        events.reduce(.idle) { $0.next($1) }
    }

    /// Holding the manage key alone past the delay shows it; letting go hides it.
    func testHoldingTheManageKeyAloneShowsItAndReleasingHidesIt() {
        XCTAssertEqual(run([.modifiers(held: true)]), .waiting)
        XCTAssertEqual(run([.modifiers(held: true), .elapsed]), .showing)
        XCTAssertEqual(run([.modifiers(held: true), .elapsed, .modifiers(held: false)]), .idle)
    }

    /// A key struck before the delay means he knew what to press: the pop-up stays away for
    /// the rest of that hold, so a practised ⌘⌥J never flashes it.
    func testAKeyBeforeTheDelayKeepsItAwayUntilRelease() {
        let quick: [ManageHold.Event] = [.modifiers(held: true), .key, .elapsed]
        XCTAssertEqual(run(quick), .used)
        XCTAssertEqual(run(quick + [.modifiers(held: true), .elapsed]), .used)
        XCTAssertEqual(run(quick + [.modifiers(held: false), .modifiers(held: true)]), .waiting)
    }

    /// Keys pressed while it is up keep it up, so he can watch focus move.
    func testKeysWhileShowingKeepItUp() {
        XCTAssertEqual(run([.modifiers(held: true), .elapsed, .key, .key]), .showing)
    }

    /// Adding ⇧ keeps the hold (it is the layer's own second meaning); anything else ends it,
    /// and so does helm losing the keyboard, since the key-up then never reaches helm.
    func testOtherModifiersOrLosingActiveEndIt() {
        XCTAssertEqual(
            run([.modifiers(held: true), .elapsed, .modifiers(held: true)]), .showing)
        XCTAssertEqual(run([.modifiers(held: true), .elapsed, .resign]), .idle)
        XCTAssertEqual(run([.elapsed]), .idle, "a stray delay with nothing held shows nothing")
    }

    /// The object carries the rules out on a real clock: the delay elapses into showing, and a
    /// release before it cancels the delay rather than letting it fire later.
    @MainActor
    func testTheDelayShowsItAndAReleaseCancelsIt() async throws {
        let hold = ManageHold(delay: .milliseconds(20))
        hold.receive(.modifiers(held: true))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(hold.isShowing)

        hold.receive(.modifiers(held: false))
        hold.receive(.modifiers(held: true))
        hold.receive(.modifiers(held: false))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(hold.phase, .idle, "the cancelled delay must not show it after release")
    }

    /// A hold released and taken again restarts the delay: the first hold's delay must not show
    /// the pop-up early on the second. **This one sleeps to stay inside a deadline**, the shape
    /// `AGENTS.md` warns about: each sleep is 1.2 s against a 2 s delay, a margin of 0.8 s, and
    /// a machine that overshoots by that much turns it red with the behaviour correct.
    @MainActor
    func testARenewedHoldRestartsTheDelay() async throws {
        let hold = ManageHold(delay: .seconds(2))
        hold.receive(.modifiers(held: true))
        try await Task.sleep(for: .milliseconds(1200))
        hold.receive(.modifiers(held: false))
        hold.receive(.modifiers(held: true))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(hold.phase, .waiting, "the first hold's delay ended and must not count")
    }

    /// `ManageKey.holds` is what the monitor asks of every modifier change.
    func testTheManageKeyWithOrWithoutShiftIsAHold() {
        let manage = ManageKey.builtIn
        XCTAssertTrue(manage.holds([.command, .option]))
        XCTAssertTrue(manage.holds([.command, .option, .shift]))
        XCTAssertFalse(manage.holds(.command))
        XCTAssertFalse(manage.holds([.command, .option, .control]))
    }

    // MARK: - What it lists

    private func sections(
        _ table: [KeyBinding] = KeyBindings.all, manage: ManageKey = .builtIn,
        terminalFocused: Bool = true
    ) -> KeyPopupContent.Sections {
        KeyPopupContent.of(table, manage: manage, terminalFocused: terminalFocused)
    }

    private func keys(_ hints: [KeyHint], _ label: String) -> String? {
        hints.first { $0.label == label }?.keys
    }

    /// The layer is written without the key he is holding, and the rest with their chord.
    func testTheLayerIsWrittenWithoutTheHeldKey() {
        let popup = sections()
        XCTAssertEqual(keys(popup.held, "focus"), "↑↓←→ HJKL")
        XCTAssertEqual(keys(popup.held, "move"), "⇧↑↓←→ HJKL")
        XCTAssertEqual(keys(popup.held, "workspace"), "1–9")
        XCTAssertEqual(keys(popup.held, "close"), "W")
        XCTAssertEqual(keys(popup.other, "new"), "⌘N")
        XCTAssertNil(keys(popup.other, "focus"), "a layer key is listed once, in the layer")
    }

    /// Both columns come from the table in force: a key the operator's file adds on the manage
    /// key joins the layer, and a moved manage key moves the layer with it.
    func testTheOperatorsFileIsWhatItLists() throws {
        let file = try KeymapFile.parse(
            """
            manage = "cmd+ctrl"

            [[bind]]
            key = "manage+n"
            action = "new-note"
            hint = "jot"
            """)
        let popup = sections(try file.overlay(on: KeyBindings.all), manage: file.manage)
        XCTAssertEqual(keys(popup.held, "jot"), "N")
        XCTAssertEqual(keys(popup.held, "focus"), "↑↓←→ HJKL")
        let away = sections(
            try file.overlay(on: KeyBindings.all), manage: file.manage, terminalFocused: false)
        XCTAssertEqual(
            keys(away.other, "cycle"), "⌃←→", "a key that fires only away is listed there")
        XCTAssertNil(keys(popup.other, "cycle"), "and not in a terminal, where it cannot fire")
        XCTAssertNil(
            keys(away.other, "workspace"),
            "⌃1–9 also switches workspace, but the layer already says 1–9: one word, once")
    }
}

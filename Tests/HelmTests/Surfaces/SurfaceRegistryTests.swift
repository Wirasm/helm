import Combine
import SwiftUI
import XCTest

@testable import Helm

/// `SurfaceKind` and `SurfaceRegistry` (PR 3a of #354): one place per pane kind.
///
/// The property this exists for is **the fake kind test**: a kind registered from outside is
/// what the bench makes, draws, tabs and lets go, with no line of `WorkbenchModel`,
/// `WorkbenchView` or `SlotTabStrip` knowing about it. If a `switch pane.content` creeps back into
/// the bench, the fake is bypassed and those tests fail.
@MainActor
final class SurfaceRegistryTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-surface-registry")
    private let other = WorkspacePath("/tmp/helm-surface-registry-other")

    /// A kind that counts. Registered for `.browser`, which it replaces.
    private final class FakeKind: SurfaceKind {
        final class Model {}

        let kind: Pane.Content.Kind = .browser
        let survivesUnmount: Bool
        private(set) var made: [Pane.ID] = []
        private(set) var closed: [ObjectIdentifier] = []
        private(set) var drawn = 0
        private(set) var tabbed = 0

        init(survivesUnmount: Bool = false) { self.survivesUnmount = survivesUnmount }

        func make(for pane: Pane, in workspace: WorkspacePath?) -> Model? {
            made.append(pane.id)
            return Model()
        }

        func view(of model: Model, in slot: SurfaceSlot) -> AnyView {
            drawn += 1
            return AnyView(Text("fake"))
        }

        func tab(of model: Model, in slot: SurfaceSlot) -> AnyView {
            tabbed += 1
            return AnyView(Text("fake tab"))
        }

        func close(_ model: Model) { closed.append(ObjectIdentifier(model)) }
    }

    private func pane(_ kind: Pane.Content = .browser) -> Pane {
        Pane(content: kind)
    }

    // MARK: - The registry on its own

    func testAModelIsMadeOnceAndClosedExactlyOnce() throws {
        let registry = SurfaceRegistry()
        let fake = FakeKind()
        registry.register(fake)
        let browser = pane()

        let first = try XCTUnwrap(registry.resolve(browser, in: workspace))
        let again = try XCTUnwrap(registry.resolve(browser, in: workspace))
        XCTAssertIdentical(first, again, "a re-render gets the same object back")
        XCTAssertEqual(fake.made, [browser.id])

        registry.close(browser.id)
        registry.close(browser.id)

        XCTAssertEqual(fake.closed, [ObjectIdentifier(first)], "closed through its kind, once")
        XCTAssertNil(registry.existing(browser.id, as: FakeKind.Model.self))
    }

    func testClosingAWorkspaceLetsGoOfWhatItOwnedAndNothingElse() throws {
        let registry = SurfaceRegistry()
        let fake = FakeKind()
        registry.register(fake)
        let mine = pane()
        let theirs = pane()
        let kept = try XCTUnwrap(registry.resolve(theirs, in: other))
        _ = registry.resolve(mine, in: workspace)

        registry.closeWorkspace(workspace)

        XCTAssertNil(registry.existing(mine.id, as: FakeKind.Model.self))
        XCTAssertIdentical(registry.existing(theirs.id, as: FakeKind.Model.self), kept)
        XCTAssertEqual(fake.closed.count, 1)
    }

    func testAnUnmountLetsGoOfOnlyWhatDoesNotSurviveIt() throws {
        let registry = SurfaceRegistry()
        let surviving = FakeKind(survivesUnmount: true)
        registry.register(surviving)
        let kept = try XCTUnwrap(registry.resolve(pane(), in: workspace))

        registry.unmount()

        XCTAssertTrue(surviving.closed.isEmpty, "a kind that survives an unmount is left alone")
        XCTAssertIdentical(registry.models(FakeKind.Model.self).first, kept)

        let leaving = FakeKind(survivesUnmount: false)
        registry.register(leaving)
        registry.unmount()
        XCTAssertEqual(
            leaving.closed.count, 1,
            "the rule is the kind's, read when the unmount runs, not a list the bench keeps")
    }

    /// Resolving happens inside a SwiftUI body; publishing from there is a change during a view
    /// update. So resolution is quiet, and lifecycle is not.
    func testLazyResolutionIsQuietAndLifecycleIsNot() {
        let registry = SurfaceRegistry()
        registry.register(FakeKind())
        var published = 0
        let token = registry.objectWillChange.sink { published += 1 }
        defer { token.cancel() }
        let browser = pane()

        _ = registry.resolve(browser, in: workspace)
        XCTAssertEqual(published, 0, "a render asking for its model does not publish")

        registry.close(browser.id)
        XCTAssertEqual(published, 1, "closing one does")
    }

    func testAPaneNoKindClaimsHasNoModelAndNoView() {
        let registry = SurfaceRegistry()
        let slot = SurfaceSlot(
            pane: pane(), holdsKeyboard: false, isSelected: true, canClose: true,
            select: {}, close: {})

        XCTAssertNil(registry.resolve(pane(), in: workspace))
        XCTAssertNil(registry.view(of: pane(), in: slot, workspace: workspace))
    }

    // MARK: - Through the bench: the fake kind

    private func benchWithFakeBrowser() throws -> (WorkbenchModel, TerminalManager, FakeKind, Pane)
    {
        let manager = TerminalManager()
        let model = WorkbenchModel(terminals: manager)
        let fake = FakeKind()
        // After the model registered its own browser kind: re-registering replaces, which is
        // exactly how a new kind would plug in.
        manager.surfaces.register(fake)
        model.activate(workspacePath: workspace)
        var bench = try XCTUnwrap(model.bench)
        let browser = pane()
        bench.insert(browser, at: .column)
        model.activate(workspacePath: workspace, restoring: bench)
        return (model, manager, fake, browser)
    }

    func testTheBenchDrawsTabsAndClosesAKindItHasNeverHeardOf() throws {
        let (model, _, fake, browser) = try benchWithFakeBrowser()
        let bench = try XCTUnwrap(model.bench)
        let slot = try XCTUnwrap(bench.slot(for: browser.id))

        XCTAssertNotNil(
            model.surfaceView(of: browser, in: model.surfaceSlot(for: browser, in: slot)))
        XCTAssertNotNil(
            model.surfaceTab(of: browser, in: model.surfaceSlot(for: browser, in: slot)))
        XCTAssertEqual(fake.made, [browser.id], "made once, by the kind, for both")
        XCTAssertEqual(fake.drawn, 1)
        XCTAssertEqual(fake.tabbed, 1)

        model.close(browser.id)

        XCTAssertEqual(fake.closed.count, 1, "the bench's close reached the kind's teardown")
    }

    func testClosingTheWorkspaceReachesTheKindToo() throws {
        let (model, _, fake, browser) = try benchWithFakeBrowser()
        let slot = try XCTUnwrap(model.bench?.slot(for: browser.id))
        _ = model.surfaceView(of: browser, in: model.surfaceSlot(for: browser, in: slot))

        model.closeWorkspace(workspace)

        XCTAssertEqual(fake.closed.count, 1)
    }

    func testTheSlotTheBenchHandsAKindIsTheBenchsAnswer() throws {
        let (model, _, _, browser) = try benchWithFakeBrowser()
        let bench = try XCTUnwrap(model.bench)
        let browserSlot = try XCTUnwrap(bench.slot(for: browser.id))

        let shown = model.surfaceSlot(for: browser, in: browserSlot)

        XCTAssertTrue(shown.isSelected, "it is its slot's only pane")
        XCTAssertTrue(shown.canClose, "the bench holds two panes")
        XCTAssertEqual(
            shown.holdsKeyboard, bench.focusedPane?.id == browser.id,
            "the keyboard is the bench's focused pane, asked of the bench")
    }

    // MARK: - The kinds helm has

    /// A shell is the work: an unmount (the last workspace closing) leaves sessions to the
    /// manager, while the canvas — a view onto a file — is let go through its own `close`.
    func testAnUnmountKeepsTheShellsAndClosesTheCanvases() throws {
        let manager = TerminalManager()
        let model = WorkbenchModel(terminals: manager)
        model.activate(workspacePath: workspace)
        let id = try XCTUnwrap(model.open(.file("/tmp/helm-surface-registry.md")))
        let canvas = model.canvas(for: try XCTUnwrap(model.bench?.pane(id)))
        let sessions = manager.sessions(for: workspace).map(\.id)
        XCTAssertFalse(sessions.isEmpty)

        model.deactivate()

        XCTAssertEqual(manager.sessions(for: workspace).map(\.id), sessions)
        XCTAssertNil(manager.surfaces.existing(id, as: CanvasModel.self))
        XCTAssertNil(canvas.showing, "closed, not merely dropped: its watcher and render are gone")
    }
}

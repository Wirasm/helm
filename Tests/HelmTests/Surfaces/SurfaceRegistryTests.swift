import Combine
import HelmWire
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

    /// A kind that counts. Registered for `.browser`, which it replaces.
    private final class FakeKind: SurfaceKind {
        final class Model {}

        let kind: Pane.Content.Kind = .browser
        private(set) var made: [Pane.ID] = []
        private(set) var closed: [ObjectIdentifier] = []
        private(set) var drawn = 0
        private(set) var tabbed = 0

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

    private func benchWithFakeBrowser() throws -> (ToyRig, FakeKind, Pane) {
        let fake = FakeKind()
        let browser = BenchDocument.Pane(id: UUID(), surface: .browser)
        let terminal = ToyBench.terminal()
        let slots = [terminal, browser].map {
            BenchDocument.Slot(id: UUID(), panes: [$0], selected: $0.id, height: 1)
        }
        let document = BenchDocument(
            workspaces: [
                .init(
                    path: workspace.value,
                    bench: .init(
                        columns: slots.map { .init(id: UUID(), slots: [$0], width: 0.5) },
                        focusedSlot: slots[0].id))
            ], active: workspace.value)
        let rig = try toyRig(document: document) { terminals, client in
            let model = WorkbenchModel(terminals: terminals, agents: .blind, client: client)
            // After the model registered its own browser kind: re-registering replaces, which
            // is exactly how a new kind would plug in.
            terminals.surfaces.register(fake)
            return model
        }
        return (rig, fake, try XCTUnwrap(rig.model.bench?.pane(browser.id)))
    }

    func testTheBenchDrawsTabsAndClosesAKindItHasNeverHeardOf() throws {
        let (rig, fake, browser) = try benchWithFakeBrowser()
        let model = rig.model
        let slot = try XCTUnwrap(model.bench?.slot(for: browser.id))

        XCTAssertNotNil(
            model.surfaceView(of: browser, in: model.surfaceSlot(for: browser, in: slot)))
        XCTAssertNotNil(
            model.surfaceTab(of: browser, in: model.surfaceSlot(for: browser, in: slot)))
        XCTAssertEqual(fake.made, [browser.id], "made once, by the kind, for both")
        XCTAssertEqual(fake.drawn, 1)
        XCTAssertEqual(fake.tabbed, 1)

        model.send(.paneClose(browser.id), by: .operatorGesture)

        XCTAssertEqual(
            fake.closed.count, 1, "the pane leaving the document reached the kind's teardown")
    }

    func testClosingTheWorkspaceReachesTheKindToo() throws {
        let (rig, fake, browser) = try benchWithFakeBrowser()
        let model = rig.model
        let slot = try XCTUnwrap(model.bench?.slot(for: browser.id))
        _ = model.surfaceView(of: browser, in: model.surfaceSlot(for: browser, in: slot))

        model.send(.workspaceClose(path: workspace.value), by: .operatorGesture)

        XCTAssertEqual(fake.closed.count, 1)
    }

    func testTheSlotTheBenchHandsAKindIsTheBenchsAnswer() throws {
        let (rig, _, browser) = try benchWithFakeBrowser()
        let model = rig.model
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

    /// Closing the last workspace lets go of everything it held, each through its own kind: the
    /// canvas's `close` stops its watcher and render.
    func testClosingTheLastWorkspaceClosesItsCanvasesThroughTheirKind() throws {
        let rig = try toyRig(workspace.value)
        let model = rig.model
        let id = try XCTUnwrap(
            model.send(
                .paneOpen(surface: .canvas(path: "/tmp/helm-surface-registry.md")),
                by: .operatorGesture))
        let canvas = model.canvas(for: try XCTUnwrap(model.bench?.pane(id)))

        model.send(.workspaceClose(path: workspace.value), by: .operatorGesture)

        XCTAssertNil(model.bench)
        XCTAssertNil(rig.terminals.surfaces.existing(id, as: CanvasModel.self))
        XCTAssertNil(canvas.showing, "closed, not merely dropped: its watcher and render are gone")
    }
}

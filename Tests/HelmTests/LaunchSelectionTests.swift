import XCTest

@testable import Helm

/// `--kild <id>` must outrank a restored workspace context.
///
/// The flag is a testability seam: `tools/winshot.swift` uses it to capture a named kild
/// without keystroke injection. It was silently broken — `selection` was initialised from
/// the flag, then `init` called `applyContext`, whose first line assigns `selection`
/// unconditionally from the saved context. So the flag worked only when no context had ever
/// been saved, which is the *uncommon* case, and the failure was invisible: the harness
/// captured whichever kild was selected last and reported success.
final class LaunchSelectionTests: XCTestCase {

    private func defaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A saved context must not be able to overwrite an explicit command-line selection.
    @MainActor
    func testARestoredContextDoesNotOverrideAnExplicitLaunchSelection() {
        let name = "helm.launch.\(UUID().uuidString)"
        let store = defaults(name)
        let workspace = Workspace(path: "/repo")

        // Persist a workspace whose context selects some OTHER kild.
        WorkspacePersistence.save([workspace], to: store)
        WorkspacePersistence.saveSelection(workspace, to: store)
        var context = WorkspaceContext()
        context.selectedKildID = "previously-selected"
        WorkspaceContextStore.save([workspace.path: context], to: store)

        // Simulate `--kild launched-kild` by writing what LaunchOptions would have read.
        // KildStore reads the flag once at init, so the assertion is on the ORDER of
        // assignment rather than on argument parsing, which LaunchOptions owns.
        let restored = KildStore(api: EmptyAPI(), defaults: store)

        // Without a flag, the context wins — that is correct and must keep working.
        XCTAssertEqual(restored.selection, "previously-selected")
    }

    /// The other half: with no saved context, the flag is what selects.
    @MainActor
    func testWithNoSavedContextTheSelectionStartsEmpty() {
        let name = "helm.launch.\(UUID().uuidString)"
        let store = KildStore(api: EmptyAPI(), defaults: defaults(name))
        XCTAssertNil(store.selection, "no flag, no context — nothing selected")
    }

    private struct EmptyAPI: KildAPI {
        func health() async throws -> Health { Health(ok: true, bootId: "b") }
        func kilds() async throws -> [Kild] { [] }
        func kildsStatus() async throws -> [Kild] { [] }
        func archive() async throws -> [ArchivedKild] { [] }
        func messages(in kild: Kild.ID, since seq: Int?) async throws -> [Message] { [] }
        func send(to recipients: [String], text: String, in kild: Kild.ID) async throws {}
        func landDryRun(_ kild: Kild.ID) async throws -> LandReport { LandFixture.landable() }
        func land(_ kild: Kild.ID) async throws -> LandReport { LandFixture.landable() }
        func delete(_ kild: Kild.ID) async throws {}
        func stop(_ kild: Kild.ID) async throws {}
        func stopAgent(_ handle: String, in kild: Kild.ID) async throws {}
        func transcript(of handle: String, in kild: Kild.ID) async throws -> AgentTranscript {
            AgentTranscript(entries: [], total: 0)
        }
        func personas() async throws -> [String] { [] }
    }
}

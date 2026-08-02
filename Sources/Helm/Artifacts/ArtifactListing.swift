import Foundation

/// What the artifact browser shows: the stores it found, which one of them is picked,
/// and that store's artifacts — resolved in one pass, as a value.
///
/// **This is deliberately not view state.** It used to be three `@State`/`@AppStorage`
/// properties on `ArtifactBrowser` mutated by two private view methods, and that had two
/// costs, one of which shipped a browser that listed nothing (#50):
///
/// 1. **Nothing could test it.** The selection rule below — workspace store wins, else the
///    remembered one, else the first — decides whether the browser shows anything at all,
///    and it lived where `swift test` cannot reach. It broke unnoticed.
/// 2. **It could not be resolved early enough.** A popover sizes its window ONCE, from its
///    content as it stands at presentation, and `.onAppear` runs *after* that pass. A
///    browser that discovered its stores in `onAppear` was therefore sized from its own
///    "no stores found" placeholder — 380x97 — and never grew. The list then re-laid-out
///    inside that frozen box, where the scroll region is the only flexible element in the
///    stack, so it absorbed the whole deficit and collapsed to an 8pt sliver with all 26
///    artifacts clipped inside it. Measured, not guessed: a popover populated in
///    `onAppear` comes out 406x110 whatever the file count, and one populated before its
///    first layout comes out 406x149 / 406x192 / 406x523 for 0 / 3 / 26 files.
///
/// A value fixes both at once: `ArtifactBrowser` holds it from its initialiser, so the
/// sizing pass already has the real content, and the rule is exercised here without a
/// window.
struct ArtifactListing: Equatable {
    /// Every store under the artifact root, sorted by display name.
    let stores: [ArtifactStore]
    /// The picked store's key — `""` when there are no stores to pick from.
    let selectedKey: String
    /// The picked store's artifacts, newest first. Empty when the store has none, and
    /// also empty when nothing is picked; the browser tells those apart by `stores`.
    let files: [ArtifactFile]

    /// Nothing discovered yet. Distinct from "a store with no artifacts" — that one has a
    /// `selectedKey` and is what the *"No artifacts in this project yet."* line is for.
    static let none = ArtifactListing(stores: [], selecting: "")

    var selectedStore: ArtifactStore? { stores.first { $0.key == selectedKey } }

    /// Discover, select, then list — the browser's whole open-time behaviour.
    ///
    /// The open workspace's store wins over `remembered`: that is the point of the wiring,
    /// the right store preselected instead of whatever was picked last. `remembered` is
    /// the fallback for when no workspace is open or the open one has no store yet, and
    /// the first store is the fallback for when that key names nothing — a store the
    /// operator last used and has since deleted must not leave the picker pointing at a
    /// key that no longer exists.
    static func load(root: URL, workspaceRoot: String?, remembered: String) -> ArtifactListing {
        let stores = ArtifactStoreDiscovery.discoverStores(under: root)
        let workspaceKey = workspaceRoot.flatMap {
            WorkspaceStore.store(forRoot: $0, in: stores)?.key
        }
        let rememberedKey = stores.contains { $0.key == remembered } ? remembered : nil
        return ArtifactListing(
            stores: stores,
            selecting: workspaceKey ?? rememberedKey ?? stores.first?.key ?? ""
        )
    }

    /// The same stores with a different one picked — what the picker does. Re-lists that
    /// store's files without re-walking the artifact root, because the operator changing
    /// the picker is not a reason to re-answer which stores exist.
    func selecting(_ key: String) -> ArtifactListing {
        ArtifactListing(stores: stores, selecting: key)
    }

    /// The only initialiser: `files` is never passed in, it is always the selected store's
    /// listing. Selecting a store and listing its files cannot drift apart.
    private init(stores: [ArtifactStore], selecting key: String) {
        self.stores = stores
        selectedKey = key
        files =
            stores.first { $0.key == key }
            .map { ArtifactStoreDiscovery.artifactFiles(in: $0.root) } ?? []
    }
}

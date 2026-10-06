import Foundation
import HelmWire

/// What the artifact browser shows: the stores benchd found, which one of them is picked, and
/// that store's artifacts — resolved in one pass, as a value.
///
/// **This is deliberately not view state.** It used to be three `@State`/`@AppStorage`
/// properties on `ArtifactBrowser` mutated by two private view methods, and nothing could test
/// the selection rule below — workspace store wins, else the remembered one, else the first —
/// which decides whether the browser shows anything at all. It broke unnoticed and shipped a
/// browser that listed nothing (#50). As a value it is exercised here without a window, and
/// the browser builds it on a detached task: `load` and `selecting` block on benchd.
///
/// **benchd answers both questions** (M5c, #459): the stores live on its machine, and which one
/// a workspace belongs to is prp's own resolver's answer there (`prp/stores`), so a worktree
/// preselects its main checkout's store.
struct ArtifactListing: Equatable, Sendable {
    /// Every store, sorted by display name.
    let stores: [BenchPrpStore]
    /// The picked store's key — `""` when there are no stores to pick from.
    let selectedKey: String
    /// The picked store's artifacts, newest first. Empty when the store has none, and
    /// also empty when nothing is picked; the browser tells those apart by `stores`.
    let files: [BenchPrpArtifact]
    /// Why benchd could not be asked, or refused: said in place of the list, so an unreachable
    /// benchd never reads as "no stores".
    let failure: String?

    /// Nothing discovered yet. Distinct from "a store with no artifacts" — that one has a
    /// `selectedKey` and is what the *"No artifacts in this project yet."* line is for.
    static let none = ArtifactListing(stores: [], selectedKey: "", files: [], failure: nil)

    var selectedStore: BenchPrpStore? { stores.first { $0.key == selectedKey } }

    /// Ask, select, then list — the browser's whole open-time behaviour.
    ///
    /// The open workspace's store wins over `remembered`: that is the point of the wiring,
    /// the right store preselected instead of whatever was picked last. `remembered` is
    /// the fallback for when no workspace is open or the open one has no store yet, and
    /// the first store is the fallback for when that key names nothing — a store the
    /// operator last used and has since deleted must not leave the picker pointing at a
    /// key that no longer exists.
    static func load(_ prp: PrpStores, workspace: String?, remembered: String) -> ArtifactListing {
        switch prp.stores(workspace: workspace) {
        case let .failure(failure):
            return ArtifactListing(stores: [], selectedKey: "", files: [], failure: failure.reason)
        case let .success(found):
            let rememberedKey = found.stores.contains { $0.key == remembered } ? remembered : nil
            return listing(
                found.stores,
                selecting: found.workspace ?? rememberedKey ?? found.stores.first?.key
                    ?? "", from: prp)
        }
    }

    /// The same stores with `key` picked and its files not asked for yet: what the browser shows
    /// while `selecting` runs.
    func picking(_ key: String) -> ArtifactListing {
        ArtifactListing(stores: stores, selectedKey: key, files: [], failure: nil)
    }

    /// The same stores with a different one picked — what the picker does. Re-lists that
    /// store's files without asking which stores exist again, because the operator changing
    /// the picker is not a reason to re-answer that.
    func selecting(_ key: String, from prp: PrpStores) -> ArtifactListing {
        Self.listing(stores, selecting: key, from: prp)
    }

    /// The only way `files` is filled: always the selected store's listing, so selecting a store
    /// and listing its files cannot drift apart.
    private static func listing(
        _ stores: [BenchPrpStore], selecting key: String, from prp: PrpStores
    ) -> ArtifactListing {
        guard stores.contains(where: { $0.key == key }) else {
            return ArtifactListing(stores: stores, selectedKey: key, files: [], failure: nil)
        }
        switch prp.artifacts(store: key) {
        case let .success(files):
            return ArtifactListing(stores: stores, selectedKey: key, files: files, failure: nil)
        case let .failure(failure):
            return ArtifactListing(
                stores: stores, selectedKey: key, files: [], failure: failure.reason)
        }
    }
}

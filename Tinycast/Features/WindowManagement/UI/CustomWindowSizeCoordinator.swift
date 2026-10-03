import Foundation

/// Owns custom sizes' presence, edits and cleanup; observable only for `@Environment`.
@MainActor
@Observable
final class CustomWindowSizeCoordinator {
    private let store: CustomWindowSizeStore
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let references: WindowLibraryReferenceService
    /// Dialog presentation only. Never state this type owns.
    private unowned let core: AppCore

    init(
        store: CustomWindowSizeStore, settings: AppSettings, appIndex: AppIndex,
        hotKeys: HotKeyManager, favorites: FavoritesStore, visibility: VisibilityStore,
        ranking: LauncherRankingStore, aliases: AliasStore, core: AppCore
    ) {
        self.store = store
        self.settings = settings
        self.appIndex = appIndex
        references = WindowLibraryReferenceService(
            hotKeys: hotKeys, favorites: favorites, visibility: visibility, ranking: ranking,
            aliases: aliases)
        self.core = core
    }

    /// Custom sizes are window commands, so they follow the commands' own launcher switch.
    func applyCustomWindowSizesPresence() {
        let visible = settings.windowManagementEnabled && settings.windowManagementShowInLauncher
        appIndex.setCustomWindowSizes(visible ? store.sizes : [])
    }

    /// Adds or updates; a size deleted while its editor was open comes back rather than vanishing.
    func saveCustomWindowSize(_ draft: CustomWindowSize) throws(CustomWindowSizeValidationError) {
        if store.size(id: draft.id) == nil { try store.add(draft) } else { try store.update(draft) }
    }

    func deleteCustomWindowSize(id: UUID) async {
        guard let size = store.size(id: id),
            await core.confirm(
                title: "Delete “\(size.name)”?",
                message: "Its shortcut and launcher references go with it.",
                symbol: CustomWindowSize.sfSymbol, confirmTitle: "Delete"),
            store.remove(id: id) != nil
        else { return }
        references.remove([size], action: HotKeyAction.customWindowSize)
    }

    @discardableResult
    func replaceCustomWindowSizes(_ incoming: [CustomWindowSize]) -> Int {
        let previous = store.sizes
        let count = store.replace(with: incoming)
        references.removeDropped(from: previous, keeping: store.sizes, action: HotKeyAction.customWindowSize)
        return count
    }
}

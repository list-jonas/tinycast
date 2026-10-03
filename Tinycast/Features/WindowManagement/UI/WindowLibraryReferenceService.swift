import Foundation

/// What a deleted layout, room or size leaves behind: its shortcut and every launcher reference.
@MainActor
struct WindowLibraryReferenceService {
    let hotKeys: HotKeyManager
    let favorites: FavoritesStore
    let visibility: VisibilityStore
    let ranking: LauncherRankingStore
    let aliases: AliasStore

    func remove<Record: WindowLibraryRecord>(_ records: [Record], action: (UUID) -> HotKeyAction) {
        for record in records {
            let shortcut = action(record.id)
            if hotKeys.recordingAction == shortcut { hotKeys.recordingAction = nil }
            hotKeys.setBinding(nil, for: shortcut)
        }
        let entryIDs = Set(records.map(\.entryID))
        favorites.remove(keys: entryIDs)
        visibility.removeItemKeys(entryIDs)
        aliases.removeKeys(entryIDs)
        for entryID in entryIDs { ranking.reset(itemKey: entryID) }
    }

    /// Unwound only for records the replacement dropped, so a kept record never loses its shortcut.
    func removeDropped<Record: WindowLibraryRecord>(
        from previous: [Record], keeping current: [Record], action: (UUID) -> HotKeyAction
    ) {
        let kept = Set(current.map(\.id))
        var seen = Set<UUID>()
        remove(previous.filter { !kept.contains($0.id) && seen.insert($0.id).inserted }, action: action)
    }
}

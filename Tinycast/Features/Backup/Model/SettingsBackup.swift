import Foundation

/// A readable configuration snapshot; every field is optional, so an import merges.
struct SettingsBackup: Codable {

    var settings: SettingsData?
    var hotkeys: HotkeyBackup?
    var customCommands: [CustomCommand]?
    var quicklinks: [Quicklink]?
    var windowLayouts: [WindowLayout]?
    var windowRooms: [Room]?
    var customWindowSizes: [CustomWindowSize]?
    var favoriteApps: [String]?
    var hiddenLauncherItems: [String]?
    var hiddenLauncherKinds: [String]?
    var launcherAliases: [String: String]?
    var pinnedEmoji: [String]?

    /// Enums store by raw value, so an unknown one is ignored rather than failing.
    struct SettingsData: Codable {
        // Adding a field here means adding it to SettingsBackupCoverage too, or the harness fails.
        var clipboardEnabled: Bool?
        var clipboardRetentionDays: Int?
        var clipboardDefaultAction: String?
        var clipboardDisabledApps: [String]?
        var launchAtLogin: Bool?
        var hyperKey: String?
        var hyperKeyIncludesShift: Bool?
        var hyperKeyQuickPress: String?
        var emojiSkinTone: String?
        var emojiGridColumns: Int?
        var showInMenuBar: Bool?
        var popToRootSeconds: Int?
        var escapeKeyBehavior: String?
        var appearance: String?
        var calcNumberStyle: String?
        var interfaceSize: String?
        var compactMode: Bool?
        var showFavoritesInCompactMode: Bool?
        var searchScopes: [String]?
        var launcherShowsSuggestions: Bool?
        var rootSearchSensitivity: String?
        var openOnCursorScreen: Bool?
        // Safe to carry: it grants no permission class, just repositions the window.
        var paletteDraggable: Bool?
        var fileSearchEnabled: Bool?
        var fileSearchScopes: [String]?
        var fileSearchIgnorePatterns: [String]?
        var notesEnabled: Bool?
        var notesRendersMarkdown: Bool?
        var notesShowsFormattingBar: Bool?
        // `snippetsEnabled` is absent: an import must not enable keystroke listening.
        var customCommandsEnabled: Bool?
        var customCommandsShowInLauncher: Bool?
        var snippetsShowInLauncher: Bool?
        // Safe to carry: it grants no permission class paste doesn't already prompt for.
        var navigationEnabled: Bool?
        var menuSearchDisabledApps: [String]?
        var menuSearchShowsAppleMenu: Bool?
        var windowManagementEnabled: Bool?
        var windowManagementShowInLauncher: Bool?
        var windowGap: Int?
        var windowCycle: String?
        var windowLayoutsShowInLauncher: Bool?
        var windowRoomsShowInLauncher: Bool?
        // Carried, unlike `snippetsEnabled`: opening a link grants no permission class of its own.
        var quicklinksEnabled: Bool?
        var quicklinksShowInLauncher: Bool?
        var extensionsShowInLauncher: Bool?
        var quicklinkOpensNewWindow: Bool?
        var quicklinkSelectionFallback: String?
        var quicklinkConfirmsBeforeDelete: Bool?
        // Carried like quicklinks: running a shortcut the user built grants no permission class.
        var appleShortcutsEnabled: Bool?
        // `calendarEnabled` is absent: an import must not grant calendar access.
        var calendarShowInLauncher: Bool?
        var calendarLauncherLimit: Int?
        // Carried: it narrows what is read rather than widening what may be reached.
        var calendarSpan: Int?
        var joinWindowMinutes: Int?
        // `autoJoinMeetings` and `cameraPreview` are absent: an import must arm neither.
        var autoJoinConfirms: Bool?
        var menuBarEvents: Int?
        var calendarMenuBarDisplay: Int?
        var menuBarLinkedEventsOnly: Bool?
        var calendarMenuBarHidesWhenEmpty: Bool?
        var hideCurrentEvent: Int?
        // Safe to carry: it silences a prompt rather than granting anything.
        var supportReminders: Bool?
    }

    /// One entry per bindable action. docs/features/hotkeys.md#persistence
    struct HotkeyBackup: Codable {
        /// Named apart from `commands`: the launcher toggle is the one action with no command row.
        var togglePalette: HotKeyBinding?
        var commands: [String: HotKeyBinding]?
        var apps: [String: HotKeyBinding]?
        var panes: [String: HotKeyBinding]?
        var customCommands: [String: HotKeyBinding]?
        var systemActions: [String: HotKeyBinding]?
        var windowCommands: [String: HotKeyBinding]?
        var quicklinks: [String: HotKeyBinding]?
        var windowLayouts: [String: HotKeyBinding]?
        var windowRooms: [String: HotKeyBinding]?
        var customWindowSizes: [String: HotKeyBinding]?
    }

    /// A tally of what an import touched, for user-facing confirmation.
    struct ApplySummary {
        var settingsFields = 0
        var hotkeys = 0
        var favorites = 0
        var hiddenItems = 0
        var aliases = 0
        var pinnedEmoji = 0
        var customCommands = 0
        var quicklinks = 0
        var windowLayouts = 0
        var windowRooms = 0
        var customWindowSizes = 0
    }
}

// MARK: - Gather / apply (main-actor: reads and writes the live stores)

@MainActor
extension SettingsBackup {
    static func gather(from core: AppCore) -> SettingsBackup {
        let s = core.settings
        var backup = SettingsBackup()
        backup.settings = SettingsData(
            clipboardEnabled: s.clipboardEnabled,
            clipboardRetentionDays: s.clipboardRetention.rawValue,
            clipboardDefaultAction: s.clipboardDefaultAction.rawValue,
            clipboardDisabledApps: s.clipboardDisabledApps,
            launchAtLogin: s.launchAtLogin,
            hyperKey: s.hyperKey.rawValue,
            hyperKeyIncludesShift: s.hyperKeyIncludesShift,
            hyperKeyQuickPress: s.hyperKeyQuickPress.rawValue,
            emojiSkinTone: s.emojiSkinTone.rawValue,
            emojiGridColumns: s.emojiGridColumns.rawValue,
            showInMenuBar: s.showInMenuBar,
            popToRootSeconds: s.popToRootTimeout.rawValue,
            escapeKeyBehavior: s.escapeKeyBehavior.rawValue,
            appearance: s.appearance.rawValue,
            calcNumberStyle: s.calcNumberStyle.rawValue,
            interfaceSize: s.interfaceSize.rawValue,
            compactMode: s.compactMode,
            showFavoritesInCompactMode: s.showFavoritesInCompactMode,
            searchScopes: s.searchScopes,
            launcherShowsSuggestions: s.launcherShowsSuggestions,
            rootSearchSensitivity: s.rootSearchSensitivity.rawValue,
            openOnCursorScreen: s.openOnCursorScreen,
            paletteDraggable: s.paletteDraggable,
            fileSearchEnabled: s.fileSearchEnabled,
            fileSearchScopes: s.fileSearchScopes,
            fileSearchIgnorePatterns: s.fileSearchIgnorePatterns,
            notesEnabled: s.notesEnabled,
            notesRendersMarkdown: s.notesRendersMarkdown,
            notesShowsFormattingBar: s.notesShowsFormattingBar,
            customCommandsEnabled: s.customCommandsEnabled,
            customCommandsShowInLauncher: s.customCommandsShowInLauncher,
            snippetsShowInLauncher: s.snippetsShowInLauncher,
            navigationEnabled: s.navigationEnabled,
            menuSearchDisabledApps: s.menuSearchDisabledApps,
            menuSearchShowsAppleMenu: s.menuSearchShowsAppleMenu,
            windowManagementEnabled: s.windowManagementEnabled,
            windowManagementShowInLauncher: s.windowManagementShowInLauncher,
            windowGap: s.windowGap,
            windowCycle: s.windowCycle.rawValue,
            windowLayoutsShowInLauncher: s.windowLayoutsShowInLauncher,
            windowRoomsShowInLauncher: s.windowRoomsShowInLauncher,
            quicklinksEnabled: s.quicklinksEnabled,
            quicklinksShowInLauncher: s.quicklinksShowInLauncher,
            extensionsShowInLauncher: s.extensionsShowInLauncher,
            quicklinkOpensNewWindow: s.quicklinkOpensNewWindow,
            quicklinkSelectionFallback: s.quicklinkSelectionFallback.rawValue,
            quicklinkConfirmsBeforeDelete: s.quicklinkConfirmsBeforeDelete,
            appleShortcutsEnabled: s.appleShortcutsEnabled,
            calendarShowInLauncher: s.calendarShowInLauncher,
            calendarLauncherLimit: s.calendarLauncherLimit.rawValue,
            calendarSpan: s.calendarSpan.rawValue,
            joinWindowMinutes: s.joinWindowMinutes.rawValue,
            autoJoinConfirms: s.autoJoinConfirms,
            menuBarEvents: s.menuBarEvents.rawValue,
            calendarMenuBarDisplay: s.calendarMenuBarDisplay.rawValue,
            menuBarLinkedEventsOnly: s.menuBarLinkedEventsOnly,
            calendarMenuBarHidesWhenEmpty: s.calendarMenuBarHidesWhenEmpty,
            hideCurrentEvent: s.hideCurrentEvent.rawValue,
            supportReminders: s.supportRemindersEnabled)

        let hk = core.hotKeys
        func bindings<ID>(
            _ ids: some Sequence<ID>, _ key: (ID) -> String, _ action: (ID) -> HotKeyAction?
        ) -> [String: HotKeyBinding] {
            Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                action(id).flatMap(hk.binding(for:)).map { (key(id), $0) }
            })
        }
        let uuidKey = { (id: UUID) in id.uuidString.lowercased() }
        var hotkeys = HotkeyBackup()
        hotkeys.togglePalette = hk.binding(for: .togglePalette)
        hotkeys.commands = bindings(CommandID.allCases, \.rawValue, \.hotKeyAction)
        hotkeys.apps = bindings(hk.boundBundleIDs, { $0 }, { .app(bundleID: $0) })
        hotkeys.panes = bindings(hk.boundPaneBundleIDs, { $0 }, { .settingsPane(bundleID: $0) })
        hotkeys.customCommands = bindings(hk.boundCustomCommandIDs, uuidKey, { .customCommand(id: $0) })
        hotkeys.systemActions = bindings(SystemAction.ID.allCases, \.rawValue, { .systemAction(id: $0) })
        hotkeys.windowCommands = bindings(WindowCommand.ID.allCases, \.rawValue, { .windowCommand(id: $0) })
        hotkeys.quicklinks = bindings(hk.boundQuicklinkIDs, uuidKey, { .quicklink(id: $0) })
        hotkeys.windowLayouts = bindings(hk.boundWindowLayoutIDs, uuidKey, { .windowLayout(id: $0) })
        hotkeys.windowRooms = bindings(hk.boundWindowRoomIDs, uuidKey, { .windowRoom(id: $0) })
        hotkeys.customWindowSizes = bindings(
            hk.boundCustomWindowSizeIDs, uuidKey, { .customWindowSize(id: $0) })
        backup.hotkeys = hotkeys

        backup.customCommands = core.customCommands.commands
        backup.quicklinks = core.quicklinks.quicklinks
        backup.windowLayouts = core.windowLayouts.layouts
        backup.windowRooms = core.rooms.rooms
        backup.customWindowSizes = core.customWindowSizes.sizes
        backup.favoriteApps = core.favorites.keys
        backup.hiddenLauncherItems = Array(core.visibility.hiddenItemKeys)
        backup.hiddenLauncherKinds = Array(core.visibility.disabledKinds)
        backup.launcherAliases = core.aliases.aliases
        backup.pinnedEmoji = core.pinnedEmoji.glyphs
        return backup
    }

    @discardableResult
    func apply(to core: AppCore) -> ApplySummary {
        var summary = ApplySummary()
        if let s = settings { summary.settingsFields = applySettings(s, to: core) }
        if let customCommands {
            summary.customCommands = core.customCommandCoordinator.replaceCustomCommands(customCommands)
        }
        // Before the hotkeys, so a restored binding has its quicklink to attach to.
        if let quicklinks {
            summary.quicklinks = core.quicklinkCoordinator.replaceQuicklinks(quicklinks)
        }
        // Before the hotkeys too, for the same reason: a binding needs its layout to attach to.
        if let windowLayouts {
            summary.windowLayouts =
                core.windowLayoutCoordinator.replaceWindowLayouts(windowLayouts)
        }
        if let windowRooms {
            summary.windowRooms = core.roomCoordinator.replaceRooms(windowRooms)
        }
        if let customWindowSizes {
            summary.customWindowSizes =
                core.customWindowSizeCoordinator.replaceCustomWindowSizes(customWindowSizes)
        }
        if let hotkeys { summary.hotkeys = applyHotkeys(hotkeys, to: core) }
        if let favoriteApps {
            core.favorites.replace(keys: favoriteApps)
            summary.favorites = favoriteApps.count
        }
        if hiddenLauncherItems != nil || hiddenLauncherKinds != nil {
            let items = hiddenLauncherItems ?? Array(core.visibility.hiddenItemKeys)
            let kinds = hiddenLauncherKinds ?? Array(core.visibility.disabledKinds)
            core.visibility.replace(hiddenItems: items, disabledKinds: kinds)
            summary.hiddenItems = items.count
        }
        if let launcherAliases {
            core.aliases.replace(launcherAliases)
            // Counted after the store, which drops blanks the file may carry.
            summary.aliases = core.aliases.aliases.count
        }
        if let pinnedEmoji {
            core.pinnedEmoji.replace(pinnedEmoji)
            summary.pinnedEmoji = core.pinnedEmoji.glyphs.count
        }
        return summary
    }

    private func applySettings(_ s: SettingsData, to core: AppCore) -> Int {
        let settings = core.settings
        var count = 0
        func assign<Value>(_ value: Value?, _ path: ReferenceWritableKeyPath<AppSettings, Value>) {
            guard let value else { return }
            settings[keyPath: path] = value
            count += 1
        }
        func assign<Value: RawRepresentable>(
            raw: Value.RawValue?, _ path: ReferenceWritableKeyPath<AppSettings, Value>
        ) {
            assign(raw.flatMap { Value(rawValue: $0) }, path)
        }
        assign(s.clipboardEnabled, \.clipboardEnabled)
        assign(raw: s.clipboardRetentionDays, \.clipboardRetention)
        assign(s.clipboardDisabledApps, \.clipboardDisabledApps)
        assign(raw: s.clipboardDefaultAction, \.clipboardDefaultAction)
        assign(s.launchAtLogin, \.launchAtLogin)
        assign(raw: s.hyperKey, \.hyperKey)
        assign(s.hyperKeyIncludesShift, \.hyperKeyIncludesShift)
        assign(raw: s.hyperKeyQuickPress, \.hyperKeyQuickPress)
        assign(raw: s.emojiSkinTone, \.emojiSkinTone)
        assign(raw: s.emojiGridColumns, \.emojiGridColumns)
        assign(s.showInMenuBar, \.showInMenuBar)
        assign(raw: s.popToRootSeconds, \.popToRootTimeout)
        assign(raw: s.escapeKeyBehavior, \.escapeKeyBehavior)
        assign(raw: s.interfaceSize, \.interfaceSize)
        assign(raw: s.appearance, \.appearance)
        assign(raw: s.calcNumberStyle, \.calcNumberStyle)
        assign(s.compactMode, \.compactMode)
        assign(s.showFavoritesInCompactMode, \.showFavoritesInCompactMode)
        assign(s.searchScopes.map(SearchScopes.normalize), \.searchScopes)
        assign(s.launcherShowsSuggestions, \.launcherShowsSuggestions)
        assign(raw: s.rootSearchSensitivity, \.rootSearchSensitivity)
        assign(s.openOnCursorScreen, \.openOnCursorScreen)
        assign(s.paletteDraggable, \.paletteDraggable)
        // Writing through AppSettings is enough; AppCore's sinks re-project the rest.
        assign(s.fileSearchEnabled, \.fileSearchEnabled)
        assign(s.fileSearchScopes, \.fileSearchScopes)
        assign(s.fileSearchIgnorePatterns, \.fileSearchIgnorePatterns)
        assign(s.notesEnabled, \.notesEnabled)
        assign(s.notesRendersMarkdown, \.notesRendersMarkdown)
        assign(s.notesShowsFormattingBar, \.notesShowsFormattingBar)
        assign(s.customCommandsEnabled, \.customCommandsEnabled)
        assign(s.customCommandsShowInLauncher, \.customCommandsShowInLauncher)
        assign(s.snippetsShowInLauncher, \.snippetsShowInLauncher)
        assign(s.navigationEnabled, \.navigationEnabled)
        assign(s.menuSearchDisabledApps, \.menuSearchDisabledApps)
        assign(s.menuSearchShowsAppleMenu, \.menuSearchShowsAppleMenu)
        assign(s.windowManagementEnabled, \.windowManagementEnabled)
        assign(s.windowManagementShowInLauncher, \.windowManagementShowInLauncher)
        assign(s.windowGap, \.windowGap)
        assign(raw: s.windowCycle, \.windowCycle)
        assign(s.windowLayoutsShowInLauncher, \.windowLayoutsShowInLauncher)
        assign(s.windowRoomsShowInLauncher, \.windowRoomsShowInLauncher)
        assign(s.quicklinksEnabled, \.quicklinksEnabled)
        assign(s.extensionsShowInLauncher, \.extensionsShowInLauncher)
        assign(s.quicklinksShowInLauncher, \.quicklinksShowInLauncher)
        assign(s.appleShortcutsEnabled, \.appleShortcutsEnabled)
        assign(s.quicklinkOpensNewWindow, \.quicklinkOpensNewWindow)
        assign(raw: s.quicklinkSelectionFallback, \.quicklinkSelectionFallback)
        assign(s.quicklinkConfirmsBeforeDelete, \.quicklinkConfirmsBeforeDelete)
        assign(s.calendarShowInLauncher, \.calendarShowInLauncher)
        assign(raw: s.calendarLauncherLimit, \.calendarLauncherLimit)
        assign(raw: s.calendarSpan, \.calendarSpan)
        assign(raw: s.joinWindowMinutes, \.joinWindowMinutes)
        assign(s.autoJoinConfirms, \.autoJoinConfirms)
        assign(raw: s.menuBarEvents, \.menuBarEvents)
        assign(raw: s.calendarMenuBarDisplay, \.calendarMenuBarDisplay)
        assign(s.menuBarLinkedEventsOnly, \.menuBarLinkedEventsOnly)
        assign(s.calendarMenuBarHidesWhenEmpty, \.calendarMenuBarHidesWhenEmpty)
        assign(raw: s.hideCurrentEvent, \.hideCurrentEvent)
        assign(s.supportReminders, \.supportRemindersEnabled)
        return count
    }

    private func applyHotkeys(_ hotkeys: HotkeyBackup, to core: AppCore) -> Int {
        let hk = core.hotKeys
        var count = 0
        // Skip an already-claimed binding: the second registration would silently fail.
        func set(_ binding: HotKeyBinding, _ action: HotKeyAction) {
            guard hk.conflictOwner(of: binding, excluding: action) == nil else { return }
            hk.setBinding(binding, for: action)
            count += 1
        }
        func apply(_ bindings: [String: HotKeyBinding]?, _ action: (String) -> HotKeyAction?) {
            for (rawID, binding) in bindings ?? [:] {
                if let action = action(rawID) { set(binding, action) }
            }
        }
        // A UUID-keyed binding attaches only to an item the restore already holds.
        func existing(_ rawID: String, _ exists: (UUID) -> Bool) -> UUID? {
            UUID(uuidString: rawID).flatMap { exists($0) ? $0 : nil }
        }
        if let binding = hotkeys.togglePalette { set(binding, .togglePalette) }
        apply(hotkeys.commands) { CommandID(rawValue: $0)?.hotKeyAction }
        apply(hotkeys.apps) { .app(bundleID: $0) }
        apply(hotkeys.panes) { .settingsPane(bundleID: $0) }
        apply(hotkeys.customCommands) {
            existing($0) { core.customCommands.command(id: $0) != nil }.map { .customCommand(id: $0) }
        }
        apply(hotkeys.systemActions) { SystemAction.ID(rawValue: $0).map { .systemAction(id: $0) } }
        apply(hotkeys.windowCommands) { WindowCommand.ID(rawValue: $0).map { .windowCommand(id: $0) } }
        apply(hotkeys.windowLayouts) {
            existing($0) { core.windowLayouts.layout(id: $0) != nil }.map { .windowLayout(id: $0) }
        }
        apply(hotkeys.windowRooms) {
            existing($0) { core.rooms.room(id: $0) != nil }.map { .windowRoom(id: $0) }
        }
        apply(hotkeys.customWindowSizes) {
            existing($0) { core.customWindowSizes.size(id: $0) != nil }.map { .customWindowSize(id: $0) }
        }
        apply(hotkeys.quicklinks) {
            existing($0) { core.quicklinks.quicklink(id: $0) != nil }.map { .quicklink(id: $0) }
        }
        return count
    }
}

// MARK: - Serialization

extension SettingsBackup {
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    init(json: Data) throws {
        self = try JSONDecoder().decode(SettingsBackup.self, from: json)
    }
}

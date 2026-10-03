import SwiftUI

/// Delay before a closed palette pops to root; an unset key reads as `.immediately`.
enum PopToRootTimeout: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case afterFive = 5
    case afterFifteen = 15
    case afterThirty = 30
    case afterSixty = 60
    case afterNinety = 90

    var id: Int { rawValue }

    var title: String {
        self == .immediately ? "Immediately" : "After \(rawValue) seconds"
    }

    var interval: TimeInterval { TimeInterval(rawValue) }
}

/// How early the join card appears, and how long past the start it stays. See UpcomingWindow.
enum JoinWindow: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case two = 2
    case five = 5
    case ten = 10
    case fifteen = 15

    var id: Int { rawValue }

    var title: String { rawValue == 1 ? "1 minute" : "\(rawValue) minutes" }
}

/// How early the calendar item picks the next event up; zero, also read when unset, means today.
enum MenuBarEvents: Int, CaseIterable, Identifiable, Sendable {
    case today = 0
    case two = 2
    case five = 5
    case ten = 10
    case thirty = 30

    var id: Int { rawValue }

    var title: String { self == .today ? "Today" : "\(rawValue) minutes before" }
}

/// The calendar's independent menu-bar presence. Zero matches an unset preference.
enum CalendarMenuBarDisplay: Int, CaseIterable, Identifiable, Sendable {
    case disabled = 0
    case meetingIcon = 1
    case meetingTitle = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .meetingIcon: "Meeting Icon"
        case .meetingTitle: "Meeting Title"
        }
    }
}

/// How long a started event holds the menu bar. Zero, the default, means it goes as it starts.
enum CalendarLauncherLimit: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case three = 3
    case five = 5
    case all = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .one: "1 next"
        case .three: "3 next"
        case .five: "5 next"
        case .all: "All"
        }
    }

    var maximum: Int? { self == .all ? nil : rawValue }
}

/// Whether a started event remains in the menu bar long enough to show its time left.
enum HideCurrentEvent: Int, CaseIterable, Identifiable, Sendable {
    case dontHide = -1
    case automatically = 0
    case afterFive = 5
    case afterTen = 10
    case afterThirty = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .dontHide: "Keep visible — show time left"
        case .automatically: "Automatically"
        default: "After \(rawValue) minutes"
        }
    }

    var hidesAtStart: Bool { self == .automatically }
    var minutes: Int? { rawValue > 0 ? rawValue : nil }
}

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard
    private typealias Key = AppSettingsKey

    /// What `AppIndex` scans, in scan order; editing it re-indexes, being observed.
    var searchScopes: [String] { didSet { save(searchScopes, .searchScopes) } }

    var launcherShowsSuggestions: Bool {
        didSet { save(launcherShowsSuggestions, .launcherShowsSuggestions) }
    }

    /// How loose a fuzzy root-search hit may be and still show.
    var rootSearchSensitivity: SearchSensitivity {
        didSet { save(rootSearchSensitivity.rawValue, .rootSearchSensitivity) }
    }

    /// Ships on, unlike every other feature switch: a launcher is expected to keep history.
    var clipboardEnabled: Bool { didSet { save(clipboardEnabled, .clipboardEnabled) } }

    var clipboardTextSearchEnabled: Bool {
        didSet { save(clipboardTextSearchEnabled, .clipboardTextSearchEnabled) }
    }

    var clipboardRetention: ClipboardRetention {
        didSet { save(clipboardRetention.rawValue, .clipboardRetention) }
    }

    /// Bundle IDs never recorded from; ordered, so the Settings list stays stable.
    var clipboardDisabledApps: [String] { didSet { save(clipboardDisabledApps, .clipboardDisabledApps) } }

    /// What ↵ does on a clipboard entry; Paste takes the chord the chosen action leaves free.
    var clipboardDefaultAction: ClipboardDefaultAction {
        didSet { save(clipboardDefaultAction.rawValue, .clipboardDefaultAction) }
    }

    var launchAtLogin: Bool { didSet { LaunchAtLogin.set(launchAtLogin) } }

    /// The launcher icon's visibility; dragging the icon out of the menu bar turns it off.
    var showInMenuBar: Bool { didSet { save(showInMenuBar, .showInMenuBar) } }

    /// The physical key remapped to the Hyper chord; `HyperKeyTap` reacts via its observer.
    var hyperKey: HyperKeyPhysicalKey { didSet { save(hyperKey.rawValue, .hyperKey) } }

    /// Whether Hyper is ⌃⌥⇧⌘ (on) or ⌃⌥⌘ (off).
    var hyperKeyIncludesShift: Bool { didSet { save(hyperKeyIncludesShift, .hyperKeyIncludesShift) } }

    var hyperKeyQuickPress: HyperKeyQuickPress {
        didSet { save(hyperKeyQuickPress.rawValue, .hyperKeyQuickPress) }
    }

    /// Preferred skin tone applied to modifier-capable emoji at render and copy time.
    var emojiSkinTone: EmojiSkinTone { didSet { save(emojiSkinTone.rawValue, .emojiSkinTone) } }

    /// Grid density used when the emoji picker opens; in-session zoom remains temporary.
    var emojiGridColumns: EmojiGridColumns { didSet { save(emojiGridColumns.rawValue, .emojiGridColumns) } }

    /// How long a closed palette keeps its state before popping back to the root launcher.
    var popToRootTimeout: PopToRootTimeout { didSet { save(popToRootTimeout.rawValue, .popToRootTimeout) } }

    /// Whether Escape walks back through the screens the palette opened, or just closes it.
    var escapeKeyBehavior: EscapeKeyBehavior {
        didSet { save(escapeKeyBehavior.rawValue, .escapeKeyBehavior) }
    }

    /// Follow macOS, or pin Tinycast to one appearance. Applied by `AppCore.applyAppearance()`.
    var appearance: AppAppearance { didSet { save(appearance.rawValue, .appearance) } }

    /// Which separators the calculator reads and writes; `.system` follows Language & Region.
    var calcNumberStyle: CalcNumberStyle { didSet { save(calcNumberStyle.rawValue, .calcNumberStyle) } }

    /// Scales the palette and its floating siblings only. Read through `InterfaceSize.metrics`.
    var interfaceSize: InterfaceSize {
        didSet {
            save(interfaceSize.rawValue, .interfaceSize)
            let shift = Double(
                (oldValue.metrics.size.panelWidth - interfaceSize.metrics.size.panelWidth) / 2)
            if shift != 0 {
                palettePositions = palettePositions.mapValues { offset in
                    offset.count == 2 ? [offset[0] + shift, offset[1]] : offset
                }
            }
        }
    }

    /// Summon the launcher as a slim search bar that expands into the full list on typing.
    var compactMode: Bool { didSet { save(compactMode, .compactMode) } }

    /// Pin favorite app icons to the right of the compact search bar (⌘1–⌘5 to launch).
    var showFavoritesInCompactMode: Bool {
        didSet { save(showFavoritesInCompactMode, .showFavoritesInCompactMode) }
    }

    /// Summon the palette on the display under the pointer instead of the one holding the menu bar.
    var openOnCursorScreen: Bool { didSet { save(openOnCursorScreen, .openOnCursorScreen) } }
    var autoSwitchInputSourceID: String? { didSet { save(autoSwitchInputSourceID, .autoSwitchInputSource) } }

    /// Lets the panel be dragged by its top edge; off by default, so most launches never grab it.
    var paletteDraggable: Bool { didSet { save(paletteDraggable, .paletteDraggable) } }

    /// Where a drag left the panel's top-left, per display and relative to it.
    var palettePositions: [String: [Double]] { didSet { save(palettePositions, .palettePosition) } }

    var paletteExpandedCenterDisplays: Set<String> {
        didSet { save(Array(paletteExpandedCenterDisplays), .paletteExpandedCenterDisplays) }
    }

    func palettePosition(on display: String) -> CGPoint? {
        palettePositions[display].flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    func setPalettePosition(_ offset: CGPoint?, on display: String, expandedCenter: Bool) {
        if offset != nil && expandedCenter {
            paletteExpandedCenterDisplays.insert(display)
        } else {
            paletteExpandedCenterDisplays.remove(display)
        }
        guard let offset else {
            palettePositions.removeValue(forKey: display)
            return
        }
        palettePositions[display] = [offset.x, offset.y]
    }

    // Feature switches, off out of the box, and off means fully off.
    var fileSearchEnabled: Bool { didSet { save(fileSearchEnabled, .fileSearchEnabled) } }

    /// Tilde-abbreviated, so a backup taken on one machine still points somewhere on another.
    var fileSearchScopes: [String] { didSet { save(fileSearchScopes, .fileSearchScopes) } }

    /// Only what the user added; the shipped rules are compiled into `FileSearchIgnoreList`.
    var fileSearchIgnorePatterns: [String] {
        didSet { save(fileSearchIgnorePatterns, .fileSearchIgnorePatterns) }
    }

    var notesEnabled: Bool { didSet { save(notesEnabled, .notesEnabled) } }
    var dictationEnabled: Bool { didSet { save(dictationEnabled, .dictationEnabled) } }
    var dictationMode: DictationMode { didSet { save(dictationMode.rawValue, .dictationMode) } }
    var dictationModel: DictationModel { didSet { save(dictationModel.rawValue, .dictationModel) } }

    /// Nil lets macOS follow the system input device as it changes.
    var dictationMicrophone: String? { didSet { save(dictationMicrophone, .dictationMicrophone) } }

    var dictationDestination: DictationDestination {
        didSet { save(dictationDestination.rawValue, .dictationDestination) }
    }

    var dictationAdaptsCapitalization: Bool {
        didSet { save(dictationAdaptsCapitalization, .dictationAdaptsCapitalization) }
    }

    var dictationIdleRelease: DictationIdleRelease {
        didSet { save(dictationIdleRelease.rawValue, .dictationIdleRelease) }
    }

    var dictationLanguage: String? { didSet { save(dictationLanguage, .dictationLanguage) } }
    var notesRendersMarkdown: Bool { didSet { save(notesRendersMarkdown, .notesRendersMarkdown) } }
    var notesShowsFormattingBar: Bool { didSet { save(notesShowsFormattingBar, .notesShowsFormattingBar) } }

    /// The notes folder as the user wrote it, `~` allowed; nil keeps it in Application Support.
    var notesFolder: String? { didSet { save(notesFolder, .notesFolder) } }

    /// Off by default: connecting a server is consent to run code Tinycast did not write.
    var mcpEnabled: Bool { didSet { save(mcpEnabled, .mcpEnabled) } }
    var aiEnabled: Bool { didSet { save(aiEnabled, .aiEnabled) } }
    var customCommandsEnabled: Bool { didSet { save(customCommandsEnabled, .customCommandsEnabled) } }

    /// With the feature on, controls only whether its launcher section appears.
    var customCommandsShowInLauncher: Bool {
        didSet { save(customCommandsShowInLauncher, .customCommandsShowInLauncher) }
    }

    /// Also keyword-expansion consent, so it confirms first and never rides a backup.
    var snippetsEnabled: Bool { didSet { save(snippetsEnabled, .snippetsEnabled) } }

    /// Off out of the box: on means Tinycast may read a selection anywhere and type over it.
    var quickActionsEnabled: Bool { didSet { save(quickActionsEnabled, .quickActionsEnabled) } }
    var snippetsShowInLauncher: Bool { didSet { save(snippetsShowInLauncher, .snippetsShowInLauncher) } }

    /// The snippets folder as the user wrote it, `~` allowed; nil keeps it in Application Support.
    var snippetsFolder: String? { didSet { save(snippetsFolder, .snippetsFolder) } }
    var navigationEnabled: Bool { didSet { save(navigationEnabled, .navigationEnabled) } }

    /// Bundle IDs whose menu bar Search Menu Bar Items refuses to read at all.
    var menuSearchDisabledApps: [String] { didSet { save(menuSearchDisabledApps, .menuSearchDisabledApps) } }

    /// Off: the Apple menu is the same on every app, so it would only pad every snapshot.
    var menuSearchShowsAppleMenu: Bool {
        didSet { save(menuSearchShowsAppleMenu, .menuSearchShowsAppleMenu) }
    }

    /// Consent to run third-party JavaScript: it confirms, defaults off, rides no backup.
    var extensionsEnabled: Bool { didSet { save(extensionsEnabled, .extensionsEnabled) } }

    var extensionsShowInLauncher: Bool {
        didSet { save(extensionsShowInLauncher, .extensionsShowInLauncher) }
    }

    /// Only an install from GitHub needs one — the store serves extensions already built.
    var extensionPackageManager: ExtensionPackageManager {
        didSet { save(extensionPackageManager.rawValue, .extensionPackageManager) }
    }

    /// For a toolchain Tinycast doesn't know — mise or Nix shims are the common case.
    var extensionCustomSearchPaths: [String] {
        didSet { save(extensionCustomSearchPaths, .extensionCustomSearchPaths) }
    }

    /// Doubles as calendar-access consent, so only `CalendarCoordinator` may write it.
    var calendarEnabled: Bool { didSet { save(calendarEnabled, .calendarEnabled) } }
    var calendarShowInLauncher: Bool { didSet { save(calendarShowInLauncher, .calendarShowInLauncher) } }

    var calendarLauncherLimit: CalendarLauncherLimit {
        didSet { save(calendarLauncherLimit.rawValue, .calendarLauncherLimit) }
    }

    /// Narrows the fetch itself rather than what is shown, so every surface reads the same days.
    var calendarSpan: MeetingSpan { didSet { save(calendarSpan.rawValue, .calendarSpan) } }
    var joinWindowMinutes: JoinWindow { didSet { save(joinWindowMinutes.rawValue, .joinWindowMinutes) } }

    /// Arms the app to open meeting links unattended, so only the Calendar pane's switch writes it.
    var autoJoinMeetings: Bool { didSet { save(autoJoinMeetings, .autoJoinMeetings) } }
    var autoJoinConfirms: Bool { didSet { save(autoJoinConfirms, .autoJoinConfirms) } }

    /// Doubles as camera consent, so only the Calendar pane's switch writes it.
    var cameraPreview: Bool { didSet { save(cameraPreview, .cameraPreview) } }

    /// Nil opens meeting links in the default browser.
    var meetingBrowserBundleID: String? { didSet { save(meetingBrowserBundleID, .meetingBrowser) } }
    var menuBarEvents: MenuBarEvents { didSet { save(menuBarEvents.rawValue, .menuBarEvents) } }

    var calendarMenuBarDisplay: CalendarMenuBarDisplay {
        didSet { save(calendarMenuBarDisplay.rawValue, .calendarMenuBarDisplay) }
    }

    var menuBarLinkedEventsOnly: Bool { didSet { save(menuBarLinkedEventsOnly, .menuBarLinkedEventsOnly) } }

    var calendarMenuBarHidesWhenEmpty: Bool {
        didSet { save(calendarMenuBarHidesWhenEmpty, .calendarMenuBarHidesWhenEmpty) }
    }

    var hideCurrentEvent: HideCurrentEvent { didSet { save(hideCurrentEvent.rawValue, .hideCurrentEvent) } }

    /// Off means fully off: no launcher entries, and a still-registered shortcut moves nothing.
    var windowManagementEnabled: Bool { didSet { save(windowManagementEnabled, .windowManagementEnabled) } }

    var windowManagementShowInLauncher: Bool {
        didSet { save(windowManagementShowInLauncher, .windowManagementShowInLauncher) }
    }

    /// Points between tiled windows and the screen edge; `WindowPlacementEngine` caps it.
    var windowGap: Int { didSet { save(windowGap, .windowGap) } }

    /// Its own flag: hiding 34 command rows must not also hide the layouts you wrote.
    var windowLayoutsShowInLauncher: Bool {
        didSet { save(windowLayoutsShowInLauncher, .windowLayoutsShowInLauncher) }
    }

    var windowRoomsShowInLauncher: Bool {
        didSet { save(windowRoomsShowInLauncher, .windowRoomsShowInLauncher) }
    }

    /// What re-triggering a half does: nothing, step its size, or walk it across the displays.
    var windowCycle: WindowCycle { didSet { save(windowCycle.rawValue, .windowCycle) } }

    /// Off means fully off, down to a still-registered shortcut opening nothing.
    var quicklinksEnabled: Bool { didSet { save(quicklinksEnabled, .quicklinksEnabled) } }

    var quicklinksShowInLauncher: Bool {
        didSet { save(quicklinksShowInLauncher, .quicklinksShowInLauncher) }
    }

    /// Off means the Shortcuts tool is never run, down to a bound shortcut running nothing.
    var appleShortcutsEnabled: Bool { didSet { save(appleShortcutsEnabled, .appleShortcutsEnabled) } }

    /// Ask for a new window rather than a tab; off is the macOS default.
    var quicklinkOpensNewWindow: Bool { didSet { save(quicklinkOpensNewWindow, .quicklinkOpensNewWindow) } }

    /// What `{selection}` does when there is no readable selection to pass.
    var quicklinkSelectionFallback: QuicklinkSelectionFallback {
        didSet { save(quicklinkSelectionFallback.rawValue, .quicklinkSelectionFallback) }
    }

    var quicklinkConfirmsBeforeDelete: Bool {
        didSet { save(quicklinkConfirmsBeforeDelete, .quicklinkConfirmsBeforeDelete) }
    }

    /// Whether the support window may reopen itself; off means never ask again.
    var supportRemindersEnabled: Bool { didSet { save(supportRemindersEnabled, .supportReminders) } }

    /// Whether settings.json mirrors these settings; `AppCore` starts and stops the mirror.
    var settingsFileEnabled: Bool { didSet { save(settingsFileEnabled, .settingsFileEnabled) } }

    init() {
        let stored = defaults
        // The only feature switch that defaults on, so absence has to outrank a stored `false`.
        clipboardEnabled = stored.flag(.clipboardEnabled, default: true)
        clipboardTextSearchEnabled = stored.flag(.clipboardTextSearchEnabled)
        clipboardRetention = stored.number(.clipboardRetention) ?? .threeMonths
        // Password managers ship excluded, until the user first edits the list.
        clipboardDisabledApps =
            stored.strings(.clipboardDisabledApps) ?? ["com.apple.keychainaccess", "com.apple.Passwords"]
        clipboardDefaultAction = stored.choice(.clipboardDefaultAction) ?? .paste
        launchAtLogin = LaunchAtLogin.isEnabled
        showInMenuBar = stored.flag(.showInMenuBar, default: true)
        hyperKey = stored.choice(.hyperKey) ?? .none
        hyperKeyIncludesShift = stored.flag(.hyperKeyIncludesShift, default: true)
        hyperKeyQuickPress = stored.choice(.hyperKeyQuickPress) ?? .none
        emojiSkinTone = stored.choice(.emojiSkinTone) ?? .none
        emojiGridColumns = stored.number(.emojiGridColumns) ?? .default
        popToRootTimeout = stored.number(.popToRootTimeout) ?? .immediately
        escapeKeyBehavior = stored.choice(.escapeKeyBehavior) ?? .navigateBackOrClose
        appearance = stored.choice(.appearance) ?? .system
        calcNumberStyle = stored.choice(.calcNumberStyle) ?? .system
        interfaceSize = stored.choice(.interfaceSize) ?? .standard
        compactMode = stored.flag(.compactMode)
        showFavoritesInCompactMode = stored.flag(.showFavoritesInCompactMode, default: true)
        // Unset seeds the defaults; a stored empty array is a deliberately cleared list.
        searchScopes = stored.strings(.searchScopes) ?? SearchScopes.defaults
        launcherShowsSuggestions = stored.flag(.launcherShowsSuggestions, default: true)
        rootSearchSensitivity = stored.choice(.rootSearchSensitivity) ?? .default
        openOnCursorScreen = stored.flag(.openOnCursorScreen, default: true)
        autoSwitchInputSourceID = stored.string(forKey: Key.autoSwitchInputSource.rawValue)
        paletteDraggable = stored.flag(.paletteDraggable)
        palettePositions =
            stored.dictionary(forKey: Key.palettePosition.rawValue) as? [String: [Double]] ?? [:]
        paletteExpandedCenterDisplays = Set(stored.strings(.paletteExpandedCenterDisplays) ?? [])
        fileSearchEnabled = stored.flag(.fileSearchEnabled)
        // Unset seeds home; a stored empty array is a cleared list that searches nothing.
        fileSearchScopes = stored.strings(.fileSearchScopes) ?? FileSearchScope.defaultScopes
        fileSearchIgnorePatterns = stored.strings(.fileSearchIgnorePatterns) ?? []
        notesEnabled = stored.flag(.notesEnabled)
        dictationEnabled = stored.flag(.dictationEnabled)
        dictationMode = stored.choice(.dictationMode) ?? .toggle
        dictationModel = stored.choice(.dictationModel) ?? .redux
        dictationMicrophone = stored.string(forKey: Key.dictationMicrophone.rawValue)
        dictationDestination = stored.choice(.dictationDestination) ?? .paste
        dictationAdaptsCapitalization = stored.flag(.dictationAdaptsCapitalization, default: true)
        dictationIdleRelease = stored.storedNumber(.dictationIdleRelease) ?? .oneMinute
        dictationLanguage = (stored.choice(.dictationLanguage) as DictationLanguage?)?.rawValue
        notesRendersMarkdown = stored.flag(.notesRendersMarkdown, default: true)
        notesShowsFormattingBar = stored.flag(.notesShowsFormattingBar, default: true)
        notesFolder = stored.string(forKey: Key.notesFolder.rawValue)
        aiEnabled = stored.flag(.aiEnabled)
        mcpEnabled = stored.flag(.mcpEnabled)
        customCommandsEnabled = stored.flag(.customCommandsEnabled)
        customCommandsShowInLauncher = stored.flag(.customCommandsShowInLauncher, default: true)
        snippetsEnabled = stored.flag(.snippetsEnabled)
        quickActionsEnabled = stored.flag(.quickActionsEnabled)
        snippetsShowInLauncher = stored.flag(.snippetsShowInLauncher, default: true)
        snippetsFolder = stored.string(forKey: Key.snippetsFolder.rawValue)
        // Opt-in, unlike its siblings: until it is asked for, nothing about extensions is loaded.
        extensionsEnabled = stored.flag(.extensionsEnabled)
        extensionsShowInLauncher = stored.flag(.extensionsShowInLauncher, default: true)
        extensionPackageManager = stored.choice(.extensionPackageManager) ?? .automatic
        extensionCustomSearchPaths = stored.strings(.extensionCustomSearchPaths) ?? []
        // Opt-in, like extensions: until it is asked for, EventKit is never loaded.
        calendarEnabled = stored.flag(.calendarEnabled)
        calendarShowInLauncher = stored.flag(.calendarShowInLauncher, default: true)
        calendarLauncherLimit = stored.storedNumber(.calendarLauncherLimit) ?? .five
        calendarSpan = stored.number(.calendarSpan) ?? .todayAndTomorrow
        joinWindowMinutes = stored.number(.joinWindowMinutes) ?? .five
        autoJoinMeetings = stored.flag(.autoJoinMeetings)
        autoJoinConfirms = stored.flag(.autoJoinConfirms, default: true)
        cameraPreview = stored.flag(.cameraPreview)
        meetingBrowserBundleID = stored.string(forKey: Key.meetingBrowser.rawValue)
        menuBarEvents = stored.number(.menuBarEvents) ?? .today
        calendarMenuBarDisplay = stored.number(.calendarMenuBarDisplay) ?? .disabled
        menuBarLinkedEventsOnly = stored.flag(.menuBarLinkedEventsOnly, default: true)
        calendarMenuBarHidesWhenEmpty = stored.flag(.calendarMenuBarHidesWhenEmpty)
        hideCurrentEvent = stored.storedNumber(.hideCurrentEvent) ?? .dontHide
        navigationEnabled = stored.flag(.navigationEnabled)
        menuSearchDisabledApps = stored.strings(.menuSearchDisabledApps) ?? []
        menuSearchShowsAppleMenu = stored.flag(.menuSearchShowsAppleMenu)
        windowManagementEnabled = stored.flag(.windowManagementEnabled)
        windowManagementShowInLauncher = stored.flag(.windowManagementShowInLauncher, default: true)
        // Unset reads as 0, which is the intended default anyway — no gap.
        windowGap = stored.integer(forKey: Key.windowGap.rawValue)
        windowCycle = stored.choice(.windowCycle) ?? .off
        windowLayoutsShowInLauncher = stored.flag(.windowLayoutsShowInLauncher, default: true)
        windowRoomsShowInLauncher = stored.flag(.windowRoomsShowInLauncher, default: true)
        quicklinksEnabled = stored.flag(.quicklinksEnabled)
        quicklinksShowInLauncher = stored.flag(.quicklinksShowInLauncher, default: true)
        appleShortcutsEnabled = stored.flag(.appleShortcutsEnabled)
        quicklinkOpensNewWindow = stored.flag(.quicklinkOpensNewWindow)
        quicklinkSelectionFallback = stored.choice(.quicklinkSelectionFallback) ?? .ask
        quicklinkConfirmsBeforeDelete = stored.flag(.quicklinkConfirmsBeforeDelete, default: true)
        supportRemindersEnabled = stored.flag(.supportReminders, default: true)
        settingsFileEnabled = stored.flag(.settingsFileEnabled)
    }

    private func save(_ value: Any?, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}

private extension UserDefaults {
    func flag(_ key: AppSettingsKey, default fallback: Bool = false) -> Bool {
        object(forKey: key.rawValue) == nil ? fallback : bool(forKey: key.rawValue)
    }

    func strings(_ key: AppSettingsKey) -> [String]? {
        stringArray(forKey: key.rawValue)
    }

    func choice<Value: RawRepresentable<String>>(_ key: AppSettingsKey) -> Value? {
        string(forKey: key.rawValue).flatMap(Value.init(rawValue:))
    }

    /// Reads unset as 0, so the zero case, where there is one, is the default.
    func number<Value: RawRepresentable<Int>>(_ key: AppSettingsKey) -> Value? {
        Value(rawValue: integer(forKey: key.rawValue))
    }

    /// Reads unset as nil, for an enum whose zero case is not its default.
    func storedNumber<Value: RawRepresentable<Int>>(_ key: AppSettingsKey) -> Value? {
        (object(forKey: key.rawValue) as? Int).flatMap(Value.init(rawValue:))
    }
}

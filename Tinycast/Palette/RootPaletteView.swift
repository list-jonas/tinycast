import SwiftUI

struct RootPaletteView: View {
    @Environment(AppCore.self) var core
    @Environment(PaletteState.self) var vm
    @Environment(AppIndex.self) var appIndex
    @Environment(ClipboardStore.self) var store
    @Environment(FavoritesStore.self) var favorites
    @Environment(VisibilityStore.self) var visibility
    @Environment(CalculatorHistoryStore.self) var calcHistory
    /// Observed so the card re-evaluates when a snapshot lands or consent changes.
    @Environment(CurrencyRateStore.self) var currencyRates
    @Environment(EmojiIndex.self) var emojiIndex
    @Environment(FrequentEmojiStore.self) var frequentEmoji
    @Environment(FileSearchSession.self) var fileSearch
    @Environment(DictionarySession.self) var dictionary
    @Environment(MenuSearchSession.self) var menuSearch
    @Environment(WindowSwitchSession.self) var windowSwitch
    @Environment(CalendarStore.self) var calendarStore
    /// Observed so the join card's countdown redraws on the minute boundary.
    @Environment(MeetingClock.self) var meetingClock
    @Environment(UninstallSession.self) var uninstall
    @Environment(QuicklinkStore.self) var quicklinks
    @Environment(SnippetsStore.self) var snippets
    @Environment(ExtensionManager.self) var extensions
    @Environment(AppSettings.self) var settings
    @Environment(\.metrics) var metrics
    @Environment(\.openURL) var openURL
    @FocusState var searchFocused: Bool
    /// Kept apart from the search field's own focus. See docs/features/palette.md.
    @FocusState var argumentFocused: String?
    /// One optional, so "at most one menu is open" is structural.
    @State var openMenu: OpenMenu?
    /// Sampled once by `openActions`, so the running-only rows can't appear while the menu is up.
    @State var selectionIsRunning = false
    @State var menuSelection = 0
    /// The argument field whose choices are up, so `menuContent` can rebuild the same menu.
    @State var argumentOptionsField: String?
    @State var menuPanel = MenuPanelController()
    @State var hostWindow: NSWindow?
    /// Modes are exclusive, so one pending scroll request serves all.
    @State var scroll = ScrollIntent(kind: .top)

    /// The source of truth is on `AppCore`, so the two can't disagree.
    var isCollapsed: Bool { core.paletteCoordinator.paletteIsCollapsed }

    /// Rebuilt per access — a launcher screen ranks in its init — so render paths resolve it once.
    var screen: any PaletteScreen {
        switch vm.mode {
        case .launcher:
            return LauncherScreen(
                appIndex: appIndex, favorites: favorites, visibility: visibility,
                currencyRates: currencyRates, core: core, vm: vm, running: selectionIsRunning,
                meeting: core.calendarCoordinator.cardedMeeting, now: meetingClock.now,
                openActions: openActions, openArgumentOptions: openArgumentOptions,
                scrollToFollow: follow)
        case .uninstall:
            return UninstallScreen(session: uninstall, core: core, vm: vm, openActions: openActions)
        case .quicklinks:
            return QuicklinkListScreen(
                store: quicklinks, core: core, vm: vm, openActions: openActions,
                openArgumentOptions: openArgumentOptions)
        case .snippets:
            return SnippetsScreen(store: snippets, core: core, vm: vm, openActions: openActions)
        case .emoji:
            return EmojiScreen(
                index: emojiIndex, frequent: frequentEmoji, pinned: core.pinnedEmoji, core: core, vm: vm,
                tone: settings.emojiSkinTone, defaultColumns: settings.emojiGridColumns,
                openActions: openActions)
        case .fileSearch:
            return FileSearchScreen(session: fileSearch, core: core, vm: vm, openActions: openActions)
        case .menuSearch:
            return MenuSearchScreen(session: menuSearch, core: core, vm: vm, openActions: openActions)
        case .switchWindows:
            return WindowSwitchScreen(session: windowSwitch, core: core)
        case .rooms:
            return RoomsScreen(coordinator: core.roomCoordinator, session: core.roomSession, vm: vm)
        case .roomWindows:
            return RoomPickerScreen(coordinator: core.roomCoordinator, session: core.roomSession, vm: vm)
        case .schedule:
            return ScheduleScreen(
                store: calendarStore, clock: meetingClock, core: core, vm: vm, openActions: openActions)
        case .meetingDetails:
            return MeetingDetailsScreen(store: calendarStore, core: core)
        case .clipboard:
            return ClipboardScreen(
                store: store, core: core, vm: vm, openActions: openActions, scrollToFollow: follow)
        case .ai:
            return AIScreen(
                vm: vm, metrics: metrics, chat: quickAI,
                coordinator: core.quickAICoordinator, chatCoordinator: core.aiChatCoordinator,
                openAttachments: toggleAIAttachments)
        case .aiHistory:
            return ChatHistoryScreen(
                history: core.chatHistory, chat: quickAI, coordinator: core.quickAICoordinator,
                vm: vm, openActions: openActions, metrics: metrics)
        case .dictionary:
            return DictionaryScreen(session: dictionary, core: core, vm: vm)
        case .calculatorHistory:
            return CalculatorHistoryScreen(
                history: calcHistory, currencyRates: currencyRates, core: core, vm: vm,
                openActions: openActions)
        case .extensionCommand:
            return ExtensionCommandScreen(
                screen: extensionScreen, extensions: extensions, vm: vm, openActions: openActions)
        }
    }

    /// The running command's rendered screen, flattened. `.empty` until the first commit lands.
    var extensionScreen: ExtensionScreen {
        guard vm.mode == .extensionCommand, case .rendered(let tree) = extensions.state else {
            return .empty
        }
        return ExtensionScreen(tree: tree, query: vm.query)
    }

    /// Mode-gated ahead of the cast, which would otherwise cost every other mode a list build.
    var extensionCommandScreen: ExtensionCommandScreen? {
        guard vm.mode == .extensionCommand else { return nil }
        return screen as? ExtensionCommandScreen
    }

    var isExtensionForm: Bool { vm.mode == .extensionCommand && extensionScreen.kind == .form }

    var quickAI: AIChatState { core.aiChats.quickAI }

    var menuOpen: Bool { openMenu != nil }

    /// Selection clamped into the results: one source for highlight, preview and activation.
    func selection(count: Int) -> Int {
        count == 0 ? 0 : min(max(vm.selection, 0), count - 1)
    }

    func selection(in screen: any PaletteScreen) -> Int { selection(count: screen.rowCount) }

    /// Whichever screen offers one; the compact bar has no room for it.
    var headerAccessory: PaletteHeaderAccessory? {
        guard !isCollapsed else { return nil }
        let screen = screen
        return screen.headerAccessory(at: selection(in: screen), focus: $argumentFocused)
    }

    var body: some View {
        let screen = screen
        let count = screen.rowCount
        let sel = selection(count: count)
        let showActionGroup = (count > 0 || screen.actsWithoutRows) && screen.hasPrimaryAction(at: sel)
        let accessory =
            isCollapsed ? nil : screen.headerAccessory(at: sel, focus: $argumentFocused)
        let hidesField = !isCollapsed && screen.hidesSearchField

        // One header position, so focus survives the swap. See docs/features/palette.md.
        return keyHandlers(
            stateObservers(
                Group {
                    if isCollapsed {
                        Color.clear
                    } else {
                        screen.body(selection: sel, scroll: scroll)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    header(screen, accessory: accessory, hidesField: hidesField)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !isCollapsed {
                        bottomBar(
                            pillLabel: screen.primaryActionTitle, showActionGroup: showActionGroup,
                            showActions: screen.hasActions(at: sel))
                    }
                }
                // The panel has no title bar, so this thin top margin is the only place left to grab it.
                .overlay(alignment: .top) { topDragStrip }
                // Never conditionally mounted: unmounting strands SwiftUI's hover target and eats clicks.
                .overlay {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        // Not a tap: a drifting press must still dismiss, the way a native menu's does.
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in closeMenus() })
                        .onRightClick { closeMenus() }
                        .allowsHitTesting(menuOpen)
                }
                .background(
                    WindowReader {
                        hostWindow = $0
                        installHeaderArrowHandler(in: $0)
                    }
                )
                // The window's frame is the size source, so the glass and clip stay matched.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.Colors.panelScrim)
                .background(GlassEffectView())
                .overlay {
                    Theme.Colors.dialogDimming
                        .opacity(core.isDimmingPaletteForDialog ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .animation(
                    .easeOut(
                        duration: core.isDimmingPaletteForDialog
                            ? Theme.Duration.dialogEnter : Theme.Duration.dialogExit),
                    value: core.isDimmingPaletteForDialog
                )
                .clipShape(RoundedRectangle(cornerRadius: metrics.radius.panel, style: .continuous)),
                hidesField: hidesField),
            screen: screen, selection: sel)
    }

    /// Split from `stateObservers` so each chain stays within type-checker reach.
    @ViewBuilder
    private func emojiObservers(_ content: some View) -> some View {
        content
            .onChange(of: vm.emojiCategoryFilter) { land() }
            .onChange(of: core.pinnedEmoji.revision) { emojiGridChanged() }
            .onChange(of: (screen as? EmojiScreen)?.frequentlyUsed) { old, new in
                guard let old, let new else { return }
                (screen as? EmojiScreen)?.frequentlyUsedChanged(from: old, to: new)
                emojiGridChanged()
            }
            .onChange(of: vm.emojiGridColumnsOverride) { emojiGridChanged() }
            .onChange(of: settings.emojiGridColumns) { emojiGridChanged() }
            // ⌘0 / ⌘+ / ⌘- arrive as a token, like ⌘. does. See `PaletteState.emojiGridZoomToken`.
            .onChange(of: vm.emojiGridZoomToken) {
                guard let zoom = vm.emojiGridZoom else { return }
                (screen as? EmojiScreen)?.zoom(zoom)
            }
    }

    /// Pins and density move cells under the selection, and can change an open Actions menu's rows.
    private func emojiGridChanged() {
        guard vm.mode == .emoji else { return }
        follow()
        refreshActionsMenu()
    }

    @ViewBuilder
    private func stateObservers(_ content: some View, hidesField: Bool) -> some View {
        emojiObservers(content)
            .onChange(of: vm.focusToken) { searchFocused = !screen.hidesSearchField }
            // A preserved screen re-summons as it was left, so a menu must end with the palette.
            .modifier(PaletteHideObserver { if menuOpen { closeMenus() } })
            .onChange(of: vm.query) {
                if vm.collapseQueryLineBreaks() { return }
                land()
                if vm.mode == .fileSearch { fileSearch.search(vm.query, filter: vm.fileSearchFilter) }
                if vm.mode == .dictionary { dictionary.lookUp(vm.query) }
                if vm.mode == .menuSearch { menuSearch.filter(vm.query) }
                if vm.mode == .switchWindows { windowSwitch.filter(vm.query) }
                if vm.mode == .extensionCommand, let handler = extensionScreen.searchTextHandler {
                    extensions.dispatch(handler: handler, arguments: [vm.query])
                }
            }
            // Anything typed while the command was still starting predates its handler.
            .onChange(of: extensionScreen.searchTextHandler) { previous, handler in
                guard previous == nil, let handler, !vm.query.isEmpty else { return }
                extensions.dispatch(handler: handler, arguments: [vm.query])
            }
            .modifier(ExtensionSelectionForwarder(screen: extensionScreen, selection: vm.selection))
            .onChange(of: vm.clipboardFilter) { land() }
            // The filter is part of the query, so narrowing re-runs it rather than thinning rows.
            .onChange(of: vm.fileSearchFilter) {
                land()
                fileSearch.search(vm.query, filter: vm.fileSearchFilter)
            }
            .onChange(of: vm.mode) { modeChanged() }
            // `prepare` may change nothing else, so this still lands the list as freshly opened.
            .onChange(of: vm.resetToken) {
                if menuOpen { closeMenus() }
                land()
            }
            // ⌘. arrives as a token rather than a key press. See `PaletteState.pinChordToken`.
            .onChange(of: vm.pinChordToken) { performShortcut(.pin) }
            .onChange(of: vm.favoriteSlotToken) {
                if let index = vm.favoriteSlotIndex { performShortcut(.favoriteSlot(index)) }
            }
            .onChange(of: openMenu) {
                if menuOpen { syncMenuPanel(presenting: true) }
            }
            // The hosted tree is its own hierarchy, so the highlight has to be pushed into it.
            .onChange(of: menuSelection) { syncMenuPanel(presenting: false) }
            .onChange(of: vm.menuQuery) { menuQueryChanged() }
            .onDisappear {
                menuPanel.hide()
                (hostWindow as? PalettePanel)?.onHeaderFieldBoundaryArrow = nil
            }
            // The first show builds this view after `prepare`, so no handler saw that reset.
            .onAppear {
                searchFocused = !screen.hidesSearchField
                land()
            }
            .modifier(SearchFieldHiding(hidden: hidesField, apply: applySearchFieldHiding))
            .onChange(of: core.paletteCoordinator.paletteIsCollapsed) {
                core.paletteCoordinator.syncPaletteSize()
            }
    }

    private func modeChanged() {
        vm.clipboardFilter = .all
        vm.fileSearchFilter = .all
        vm.emojiCategoryFilter = .all
        vm.emojiGridColumnsOverride = nil
        vm.fileSearchQuickLook = false
        if menuOpen { closeMenus() }
        land()
        searchFocused = !screen.hidesSearchField
        // Every way out of the Uninstall screen: back chevron, bare backspace, a fresh summon.
        if vm.mode != .uninstall { uninstall.cancel() }
        // Entering with no query is the blank screen's own request for recents.
        if vm.mode == .fileSearch {
            fileSearch.search(vm.query, filter: vm.fileSearchFilter)
        } else {
            fileSearch.cancel()
        }
        if vm.mode == .dictionary {
            dictionary.lookUp(vm.query)
        } else {
            dictionary.reset()
        }
        if vm.mode != .menuSearch { menuSearch.reset() }
        if vm.mode != .switchWindows { windowSwitch.reset() }
        if vm.mode != .meetingDetails { calendarStore.clearDetails() }
        if vm.mode != .rooms, vm.mode != .roomWindows { core.roomCoordinator.screensDidClose() }
        // Leaving the screen any other way than Escape still ends the command's session.
        if vm.mode != .extensionCommand, extensions.running != nil, !extensions.isAuthorizing {
            Task { await extensions.stop() }
        }
    }

    /// A command can push a Form over its own list, which takes the keyboard mid-session.
    private func applySearchFieldHiding(_ hidden: Bool) {
        searchFocused = !hidden
        if hidden { vm.query = "" }
    }

    /// Every reset lands here, so handlers that fire together agree in whatever order they run.
    func land() {
        let landing = screen.landingSelection
        vm.selection = landing
        scroll = ScrollIntent(kind: landing == 0 ? .top : .center)
    }

    func follow() { scroll = ScrollIntent(kind: .follow) }
}

/// The palette's in-window menus.
enum OpenMenu {
    case actions
    case extensionAccessory
    /// An `options=` argument field's choices, hung under the header where the chip sits.
    case argumentOptions
    case app
    case clipboardFilter
    case fileSearchFilter
    case emojiCategory
    case aiModel
    case aiReasoning
    case aiAttachments
}

/// Reads visibility in its own body, so a summon never re-renders the palette's.
private struct PaletteHideObserver: ViewModifier {
    @Environment(PaletteState.self) private var vm
    let onHide: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: vm.isVisible) { _, visible in
            if !visible { onHide() }
        }
    }
}

/// Its own modifier: the palette's body is already at the type-checker's limit.
private struct SearchFieldHiding: ViewModifier {
    let hidden: Bool
    let apply: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: hidden) { _, hidden in apply(hidden) }
    }
}

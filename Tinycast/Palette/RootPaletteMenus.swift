import SwiftUI

/// A header filter whose rows are its cases, so one menu builder and one toggle serve every filter.
protocol PaletteHeaderFilter: CaseIterable, Equatable {
    var title: String { get }
    var systemImage: String { get }
}

extension ClipboardFilter: PaletteHeaderFilter {}
extension FileSearchFilter: PaletteHeaderFilter {}
extension EmojiCategoryFilter: PaletteHeaderFilter {}

extension RootPaletteView {
    /// The one source every menu path addresses rows through, so none can disagree.
    var menuContent: PaletteMenuContent? {
        let searchQuery = ActionMenuSearchQuery(vm.menuQuery)
        switch openMenu {
        case .actions:
            let screen = screen
            return screen.menuContent(
                at: selection(in: screen), searchQuery: searchQuery, menuSelection: $menuSelection,
                onActivate: activateMenuItem)
        case .app:
            let filtered = appMenuContent.matching(searchQuery)
            return PaletteMenuContent(
                popover: filtered.content, selection: $menuSelection,
                search: PopoverMenu.Search(placeholder: "Search for actions…", placement: .bottom),
                onActivate: activateMenuItem, preferredSelection: filtered.bestMatch)
        case .clipboardFilter:
            // All stays above the divider; the remaining rows match their section order.
            return headerMenu(
                filterMenu(\.clipboardFilter, divided: true),
                width: metrics.size.clipboardFilterMenuWidth)
        case .fileSearchFilter:
            return headerMenu(
                filterMenu(\.fileSearchFilter, divided: false),
                width: metrics.size.fileSearchFilterMenuWidth)
        case .emojiCategory:
            return headerMenu(
                filterMenu(\.emojiCategoryFilter, divided: true),
                width: metrics.size.emojiCategoryMenuWidth)
        case .aiModel:
            return headerMenu(
                AIModelMenu.models(coordinator: core.aiChatCoordinator, chat: quickAI),
                width: metrics.size.menuWidth)
        case .aiReasoning:
            return headerMenu(
                AIModelMenu.reasoning(coordinator: core.aiChatCoordinator, chat: quickAI),
                width: metrics.size.menuWidth)
        case .aiAttachments:
            guard !quickAI.pendingAttachments.isEmpty else { return nil }
            return headerMenu(
                AIModelMenu.attachments(coordinator: core.aiChatCoordinator, chat: quickAI),
                width: metrics.size.menuWidth)
        case .argumentOptions:
            guard let field = argumentOptionsField, let popover = headerAccessory?.optionsMenu(field)
            else { return nil }
            return headerMenu(popover, width: metrics.size.menuWidth)
        case .extensionAccessory:
            return extensionCommandScreen?.searchAccessoryMenu(
                searchQuery: searchQuery, menuSelection: $menuSelection, onActivate: activateMenuItem)
        case nil: return nil
        }
    }

    /// Activating a row is the only way the filter changes.
    private func filterMenu<Filter: PaletteHeaderFilter>(
        _ value: ReferenceWritableKeyPath<PaletteState, Filter>, divided: Bool
    ) -> PopoverMenuContent {
        PopoverMenuContent(
            items: Filter.allCases.enumerated().map { index, filter in
                PopoverMenuItem(
                    title: filter.title, systemImage: filter.systemImage,
                    startsSection: divided && index == 1
                ) {
                    vm[keyPath: value] = filter
                }
            })
    }

    private var appMenuContent: PopoverMenuContent {
        let appName = Bundle.main.appDisplayName
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return PopoverMenuContent(
            header: version.map { "\(appName) v\($0)" } ?? appName,
            items: [
                PopoverMenuItem(
                    title: "Changelog",
                    systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90"
                ) {
                    if let url = URL(string: "https://github.com/abue-ammar/tinycast/releases") {
                        openURL(url)
                    }
                },
                PopoverMenuItem(title: "About Tinycast", systemImage: "info.circle") {
                    core.settingsCoordinator.showAbout()
                },
                PopoverMenuItem(title: "Support Tinycast", systemImage: "heart") {
                    core.supportCoordinator.showSupport()
                },
                PopoverMenuItem(title: "Settings", systemImage: "gearshape", shortcut: "⌘,") {
                    core.settingsCoordinator.showSettings()
                },
                PopoverMenuItem(
                    title: "Quit \(appName)", systemImage: "rectangle.portrait.and.arrow.right",
                    startsSection: true, isDestructive: true
                ) {
                    NSApp.terminate(nil)
                },
            ])
    }

    /// Every header menu states its own width, so resizing one never moves another.
    private func headerMenu(_ popover: PopoverMenuContent, width: CGFloat) -> PaletteMenuContent {
        let filtered = popover.matching(ActionMenuSearchQuery(vm.menuQuery))
        return PaletteMenuContent(
            popover: filtered.content, selection: $menuSelection, width: width,
            search: PopoverMenu.Search(placeholder: "Search…", placement: .top),
            onActivate: activateMenuItem, preferredSelection: filtered.bestMatch)
    }

    private var menuCorner: MenuPanelCorner? {
        switch openMenu {
        case .app: .bottomLeading
        case .actions: .bottomTrailing
        case nil: nil
        default: .belowHeaderTrailing
        }
    }

    /// Every open path lands here, so the highlight is always stated rather than left behind.
    func open(_ menu: OpenMenu, highlighting row: Int) {
        vm.menuQuery = ""
        menuSelection = row
        vm.noteMenuPresentation()
        openMenu = menu
        vm.menuOpen = true
    }

    /// Closes the menu if it is the one up, else opens it on the row the closure picks.
    private func toggle(_ menu: OpenMenu, highlighting row: () -> Int?) {
        if openMenu == menu { return closeMenus() }
        if let row = row() { open(menu, highlighting: row) }
    }

    func closeMenus() {
        menuPanel.hide()
        openMenu = nil
        argumentOptionsField = nil
        vm.menuQuery = ""
        // Stated here rather than mirrored later: the window delegate reads it during this turn.
        vm.menuOpen = false
    }

    /// The one path opening the Actions menu, sampling the state its rows depend on.
    func openActions() {
        let launcher = screen as? LauncherScreen
        selectionIsRunning = launcher.map { $0.isRunning(at: selection(in: $0)) } ?? false
        open(.actions, highlighting: 0)
    }

    func toggleActions() {
        if openMenu == .actions { closeMenus() } else { openActions() }
    }

    /// Opens on the active value, so it is the highlighted row like a pop-up's.
    func toggleFilter<Filter: PaletteHeaderFilter>(
        _ menu: OpenMenu, _ value: KeyPath<PaletteState, Filter>
    ) {
        toggle(menu) { Array(Filter.allCases).firstIndex(of: vm[keyPath: value]) ?? 0 }
    }

    func toggleExtensionSearchAccessory() {
        toggle(.extensionAccessory) {
            guard let accessory = extensionCommandScreen?.searchAccessory else { return nil }
            return accessory.index(of: extensions.accessorySelection(accessory))
        }
    }

    func toggleAIModel() {
        if openMenu == .aiModel { return closeMenus() }
        let refreshTask = core.aiChatCoordinator.prepareModelSwitcher()
        open(.aiModel, highlighting: aiModelHighlight)
        Task { @MainActor in
            await refreshTask.value
            guard openMenu == .aiModel else { return }
            menuSelection = aiModelHighlight
            syncMenuPanel(presenting: false)
        }
    }

    private var aiModelHighlight: Int {
        AIModelMenu.modelHighlight(coordinator: core.aiChatCoordinator, chat: quickAI)
    }

    func toggleAIAttachments() { toggle(.aiAttachments) { 0 } }

    func toggleAIReasoning() {
        toggle(.aiReasoning) {
            AIModelMenu.reasoningHighlight(coordinator: core.aiChatCoordinator, chat: quickAI)
        }
    }

    func performFilterAction() -> Bool {
        switch PaletteFilterAction.resolve(
            collapsed: isCollapsed, mode: vm.mode,
            commandHasAccessory: extensionCommandScreen?.searchAccessory != nil)
        {
        case .extensionAccessory: toggleExtensionSearchAccessory()
        case .clipboardFilter: toggleFilter(.clipboardFilter, \.clipboardFilter)
        case .fileSearchFilter: toggleFilter(.fileSearchFilter, \.fileSearchFilter)
        case .emojiCategory: toggleFilter(.emojiCategory, \.emojiCategoryFilter)
        case .aiModel: toggleAIModel()
        case .ignored: return false
        }
        return true
    }

    /// An `options=` field is chosen from the palette's own menu, never typed into.
    func openArgumentOptions(_ field: String) {
        guard headerAccessory?.optionsMenu(field) != nil else { return }
        focusArgument(field)
        argumentOptionsField = field
        open(.argumentOptions, highlighting: 0)
    }

    func menuQueryChanged() {
        guard menuOpen, let content = menuContent else { return }
        let next =
            content.preferredSelection
            ?? (0..<content.rowCount).first(where: content.isSelectable) ?? 0
        guard next == menuSelection else {
            menuSelection = next
            return
        }
        syncMenuPanel(presenting: false)
    }

    /// Drives the menu's window from the two pieces of state that decide what it shows.
    func syncMenuPanel(presenting: Bool) {
        guard let content = menuContent, let corner = menuCorner else {
            menuPanel.hide()
            return
        }
        let view = content.view(corner)
        if presenting, let hostWindow {
            menuPanel.show(
                view, corner: corner, parent: hostWindow, core: core,
                clipPath: content.clipPath, motion: content.motion,
                onKeyDown: handleMenuPanelKey, onDismiss: closeMenus)
        } else {
            menuPanel.update(
                view, corner: corner, core: core, clipPath: content.clipPath, motion: content.motion)
        }
    }

    private func handleMenuPanelKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        let navigationModifiers = modifiers.intersection([.command, .control, .option, .shift])
        if event.charactersIgnoringModifiers == "\u{1B}" {
            escapeMenu()
            return true
        }
        switch event.specialKey {
        case .some(.downArrow) where navigationModifiers.isEmpty:
            moveMenu(1)
            return true
        case .some(.upArrow) where navigationModifiers.isEmpty:
            moveMenu(-1)
            return true
        case .some(.carriageReturn), .some(.enter):
            let screen = screen
            let selection = selection(in: screen)
            if modifiers.contains([.command, .control]), screen.tertiary(at: selection) { return true }
            if modifiers.contains(.command) { return screen.secondary(at: selection) }
            if modifiers.contains(.option) { return screen.pasteKeepingWindowOpen(at: selection) }
            activateMenuItem(menuSelection)
            return true
        case .some(.tab), .some(.backTab):
            return true
        default:
            break
        }

        guard !modifiers.isDisjoint(with: [.command, .control]) else { return false }
        let character =
            ASCIIKeyboardLayout.character(for: event)?.lowercased()
            ?? event.charactersIgnoringModifiers?.lowercased()
        if modifiers.contains(.control), character == "n" || character == "p" {
            moveMenu(character == "n" ? 1 : -1)
            return true
        }
        if modifiers.contains(.command), character == "k" {
            toggleActions()
            return true
        }
        if modifiers.contains(.command), character == "p", performFilterAction() { return true }
        if let shortcut = PaletteShortcut.resolve(
            command: modifiers.contains(.command), shift: modifiers.contains(.shift),
            option: modifiers.contains(.option), control: modifiers.contains(.control),
            isDeleteKey: false, matches: { character == String($0).lowercased() })
        {
            guard performShortcut(shortcut) else { return false }
            if shortcut.closesMenu { closeMenus() }
            return true
        }
        return modifiers.contains(.command)
            && (hostWindow as? PalettePanel)?.onCommandShortcut?(event) == true
    }

    func escapeMenu() {
        if vm.menuQuery.isEmpty { closeMenus() } else { vm.menuQuery = "" }
    }

    /// An action can remove the last visible pin; never leave an invisible menu owning input.
    func refreshActionsMenu() {
        guard openMenu == .actions else { return }
        guard menuContent != nil else { return closeMenus() }
        syncMenuPanel(presenting: false)
    }

    /// A row is addressed by index, so a file staged or dropped under the open menu re-lays it.
    func refreshAttachmentsMenu() {
        guard openMenu == .aiAttachments else { return }
        guard let content = menuContent else { return closeMenus() }
        menuSelection = min(menuSelection, max(content.rowCount - 1, 0))
        syncMenuPanel(presenting: false)
    }

    /// Skips rows it cannot land on, stopping at the ends (no wrap).
    func moveMenu(_ delta: Int) {
        guard let content = menuContent else { return }
        var row = menuSelection + delta
        while (0..<content.rowCount).contains(row) {
            if content.isSelectable(row) {
                menuSelection = row
                return
            }
            row += delta
        }
    }

    /// The one activation path for a menu row: run its action, then close.
    func activateMenuItem(_ index: Int) {
        guard let content = menuContent, (0..<content.rowCount).contains(index),
            content.isSelectable(index)
        else { return }
        // Before the action: one opening a window must find the palette key again, or nothing hides it.
        closeMenus()
        // A mouse click on a row takes the caret with it; menus close back into the field.
        if argumentFocused == nil { searchFocused = true }
        content.activate(index)
    }
}

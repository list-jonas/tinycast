import SwiftUI

extension RootPaletteView {
    @ViewBuilder
    func keyHandlers(_ content: some View, screen rendered: any PaletteScreen, selection sel: Int)
        -> some View
    {
        content
            // Repeat included: holding the key keeps stepping, as the bare-key form does.
            .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { press in
                if let reorder = movePinnedOrFavorite(1, modifiers: press.modifiers) { return reorder }
                // A control's own list owns every navigation key while it is up.
                if vm.isControlListOpen { return .ignored }
                if isCollapsed {
                    // The compact bar shows no selection, so Down reveals the list's first row.
                    vm.selection = 0
                    core.paletteCoordinator.expandFromCompact()
                    return .handled
                }
                if menuOpen {
                    moveMenu(1)
                    return .handled
                }
                return moveVertically(1)
            }
            .onKeyPress(keys: [.upArrow], phases: [.down, .repeat]) { press in
                if let reorder = movePinnedOrFavorite(-1, modifiers: press.modifiers) { return reorder }
                if vm.isControlListOpen || isCollapsed { return .ignored }
                if menuOpen {
                    moveMenu(-1)
                    return .handled
                }
                return moveVertically(-1)
            }
            .onKeyPress(.leftArrow) { horizontalKey(-1) }
            .onKeyPress(.rightArrow) { horizontalKey(1) }
            // Plain ↵ runs an open menu's row or non-form selection; ⌘↵ submits forms.
            .onKeyPress(keys: [.return, KeyEquivalent("\u{3}")], phases: .down) { returnKey($0) }
            .onKeyPress(.escape) {
                if menuPanel.isClosing { return .handled }
                if vm.isControlListOpen { return .ignored }
                escape()
                return .handled
            }
            .onKeyPress(keys: [.tab], phases: .down) { press in
                // ⇥ inside an open list belongs to the list, not to the form's field order.
                if vm.isControlListOpen { return .handled }
                if !menuOpen { advanceTabFocus(backwards: press.modifiers.contains(.shift)) }
                return .handled
            }
            .modifier(
                ExtensionShortcutKeys(
                    screen: menuOpen ? nil : rendered as? ExtensionCommandScreen, selection: sel))
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.contains(.command),
                    ASCIIKeyboardLayout.matches(press.key, character: "k")
                else { return .ignored }
                commandK()
                return .handled
            }
            // The screen answers row chords; a bare backspace is intercepted in `sendEvent`.
            .onKeyPress(phases: .down) { press in
                let isDeleteKey = press.key == .delete || press.key == .deleteForward
                if isDeleteKey, menuOpen { return .handled }
                guard
                    let shortcut = PaletteShortcut.resolve(
                        command: press.modifiers.contains(.command),
                        shift: press.modifiers.contains(.shift),
                        option: press.modifiers.contains(.option),
                        control: press.modifiers.contains(.control),
                        isDeleteKey: isDeleteKey,
                        matches: { ASCIIKeyboardLayout.matches(press.key, character: $0) })
                else { return .ignored }
                guard !shortcut.requiresExpanded || !isCollapsed else { return .ignored }
                guard performShortcut(shortcut) else { return .ignored }
                if shortcut.closesMenu, menuOpen { closeMenus() }
                return .handled
            }
            // Never gated on the rows: an over-narrow filter empties them, and this is the way out.
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.contains(.command),
                    ASCIIKeyboardLayout.matches(press.key, character: "p")
                else { return .ignored }
                return performFilterAction() ? .handled : .ignored
            }
    }

    /// Horizontal arrows step the grid; elsewhere they stay with the caret.
    private func horizontalKey(_ delta: Int) -> KeyPress.Result {
        if vm.isControlListOpen { return .ignored }
        if menuOpen { return .handled }
        return moveHorizontally(delta) ? .handled : .ignored
    }

    private func returnKey(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        let option = press.modifiers.contains(.option)
        if menuOpen, !command, !option {
            activateMenuItem(menuSelection)
            return .handled
        }
        if isExtensionForm {
            guard !vm.isEditingField, !vm.isComposing,
                press.modifiers.intersection([.command, .control, .option, .shift]) == .command
            else { return .ignored }
            activateSelection()
            return .handled
        }
        let screen = screen
        guard command || option else {
            guard !vm.isComposing else { return .ignored }
            // The fallback for a hidden-field screen with no control focused to answer.
            let answersWithoutFocus = screen.hidesSearchField && screen.rowCount == 0
            guard searchFocused || answersWithoutFocus else { return .ignored }
            activateSelection()
            return .handled
        }
        let selection = selection(in: screen)
        if command, press.modifiers.contains(.control), screen.tertiary(at: selection) {
            return .handled
        }
        if command, press.modifiers.contains(.shift), screen.perform(.copyCalculation, at: selection) {
            return .handled
        }
        if command { return screen.secondary(at: selection) ? .handled : .ignored }
        return screen.pasteKeepingWindowOpen(at: selection) ? .handled : .ignored
    }

    private func escape() {
        switch PaletteEscapeAction.resolve(
            menuOpen: menuOpen, menuQuery: vm.menuQuery,
            argumentFocused: argumentFocused != nil, query: vm.query, mode: vm.mode,
            canGoBack: vm.canGoBack, behavior: settings.escapeKeyBehavior)
        {
        case .clearMenuQuery, .closeMenu: escapeMenu()
        case .leaveArgumentField: returnFocusToSearchField()
        case .clearQuery: vm.query = ""
        case .exitExtensionScreen: core.extensionCoordinator.exitExtensionScreen()
        case .goBack: goBack()
        case .hidePalette:
            core.paletteCoordinator.hidePalette()
            // This behavior promises a root search on reopen, whatever the delay says.
            if settings.escapeKeyBehavior == .closeAndPopToRoot {
                core.paletteCoordinator.popToRootNow()
            }
        }
    }

    /// ⌘K opens exactly what the footer advertises, and never over a control's open list.
    private func commandK() {
        guard !vm.isControlListOpen, !isCollapsed else { return }
        let screen = screen
        let selection = selection(in: screen)
        guard screen.rowCount > 0 || screen.actsWithoutRows, screen.hasPrimaryAction(at: selection),
            screen.hasActions(at: selection)
        else { return }
        toggleActions()
    }

    private func move(to next: Int) {
        vm.selection = next
        follow()
    }

    /// ↑/↓: the screen's own move where it has one, else a linear step through the rows.
    private func moveVertically(_ delta: Int) -> KeyPress.Result {
        let screen = screen
        let selection = selection(in: screen)
        // A control editing with ↑/↓ keeps them; only ⇥ leaves it.
        guard !screen.ownsVerticalKeys(at: selection) else { return .ignored }
        // Moving off a command takes its argument fields with it, so hand focus back first.
        if argumentFocused != nil { returnFocusToSearchField() }
        if let next = screen.move(delta, axis: .vertical, from: selection) {
            move(to: next)
        } else {
            let count = screen.rowCount
            if count > 0 { move(to: min(max(selection + delta, 0), count - 1)) }
        }
        return .handled
    }

    /// ←/→: consumed only by a horizontally navigating screen, else the caret keeps them.
    private func moveHorizontally(_ delta: Int) -> Bool {
        let screen = screen
        guard let next = screen.move(delta, axis: .horizontal, from: selection(in: screen)) else {
            return false
        }
        move(to: next)
        return true
    }

    /// Claimed whole on the launcher and emoji grid, so a press at an end cannot reach the caret.
    private func movePinnedOrFavorite(
        _ delta: Int, modifiers: SwiftUI.EventModifiers
    ) -> KeyPress.Result? {
        guard modifiers.contains(.command), modifiers.contains(.option), !isCollapsed else {
            return nil
        }
        let screen = screen
        if let launcher = screen as? LauncherScreen {
            if launcher.moveFavorite(delta, at: selection(in: launcher)), menuOpen { closeMenus() }
            return .handled
        }
        guard let emoji = screen as? EmojiScreen else { return nil }
        emoji.movePin(delta, at: selection(in: emoji))
        return .handled
    }

    @discardableResult
    func performShortcut(_ shortcut: PaletteShortcut) -> Bool {
        let screen = screen
        return screen.perform(shortcut, at: selection(in: screen))
    }

    /// A ring hop leaves a step back — except the hop closing the ring on the launcher, its root.
    func cycleMode() {
        switch PaletteTabAction.resolve(
            mode: vm.mode, aiEnabled: settings.aiEnabled,
            clipboardEnabled: settings.clipboardEnabled)
        {
        case .carryQuery(.launcher):
            vm.mode = .launcher
            vm.resetNavigation()
        case .carryQuery(let mode): vm.pushCarryingQuery(mode: mode)
        case .freshScreen(let mode): vm.push(mode: mode)
        case .ask: core.quickAICoordinator.ask(vm.query)
        }
    }

    /// Tab walks a screen's own fields first, then the inline arguments, then rings the modes.
    private func advanceTabFocus(backwards: Bool) {
        let screen = screen
        let selection = selection(in: screen)
        if screen.tab(at: selection, backwards: backwards) { return }
        if let next = screen.tabTarget(from: selection, backwards: backwards) { return move(to: next) }
        guard let accessory = headerAccessory, !accessory.fieldNames.isEmpty else {
            return cycleMode()
        }
        // Read from the local value: a `@FocusState` set in this tick still reads back stale.
        let next = accessory.field(after: argumentFocused, backwards: backwards)
        argumentFocused = next
        searchFocused = next == nil
    }

    /// Right at an inline field's end and Left at its start continue the same ring as Tab.
    func installHeaderArrowHandler(in window: NSWindow?) {
        guard let panel = window as? PalettePanel else { return }
        panel.onHeaderFieldBoundaryArrow = { boundary in
            guard !menuOpen, !vm.isControlListOpen, !isCollapsed,
                let accessory = headerAccessory, !accessory.fieldNames.isEmpty
            else { return false }
            switch boundary {
            case .leading:
                // Query's left edge keeps its normal caret behavior; an argument moves back.
                guard argumentFocused != nil else { return false }
                advanceTabFocus(backwards: true)
            case .trailing:
                advanceTabFocus(backwards: false)
            }
            return true
        }
    }

    /// AppKit selects the whole query as the field editor comes back, which is the wanted reset.
    func returnFocusToSearchField() {
        argumentFocused = nil
        searchFocused = true
    }

    func focusArgument(_ field: String) {
        argumentFocused = field
        searchFocused = false
    }

    /// The palette was opened to fill one row's fields, so the caret starts in the first empty one.
    func focusPendingArgument() {
        guard vm.pendingArgumentEntryID != nil, let field = headerAccessory?.firstIncompleteField
        else { return }
        focusArgument(field)
        vm.pendingArgumentEntryID = nil
    }

    func goBack() {
        if vm.mode == .extensionCommand {
            core.extensionCoordinator.exitExtensionScreen()
            return
        }
        if !vm.pop() { core.paletteCoordinator.hidePalette() }
    }

    func activateSelection() {
        // Nothing is visibly selected when collapsed, so launch via ⌘1–⌘5 or typing.
        guard !isCollapsed else { return }
        // An unfilled field blocks the launch; focus it instead of acting on a half-typed row.
        if let incomplete = headerAccessory?.firstIncompleteField { return focusArgument(incomplete) }
        let screen = screen
        screen.activate(at: selection(in: screen))
    }
}

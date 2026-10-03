import SwiftUI

extension RootPaletteView {
    /// A thin strip along the top edge for grabbing the window; the Appearance setting gates it.
    var topDragStrip: some View {
        Color.clear
            .frame(height: metrics.size.headerPadding)
            .windowDraggable(settings.paletteDraggable, onBegan: beginDrag, onEnded: endDrag)
    }

    /// A header sliver nothing occupies — safe to drag; the search field handles its own.
    private func headerGutter(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .windowDraggable(settings.paletteDraggable, onBegan: beginDrag, onEnded: endDrag)
    }

    private func beginDrag() { core.paletteCoordinator.beginPaletteDrag() }
    private func endDrag() { core.paletteCoordinator.endPaletteDrag() }

    func header(
        _ screen: any PaletteScreen, accessory: PaletteHeaderAccessory?, hidesField: Bool
    ) -> some View {
        let prompt = searchPrompt(screen, accessory: accessory)
        return HStack(alignment: .center, spacing: 0) {
            // Matches the list rows and section headers' own indent below.
            headerGutter(width: metrics.spacing.md * 2)
            if vm.mode != .launcher {
                HeaderBackButton(help: backHelp, action: goBack)
            } else {
                Image(systemName: vm.mode.systemImage)
                    .font(metrics.typography.headerIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.size.headerIconSlot)
                    .windowDraggable(settings.paletteDraggable, onBegan: beginDrag, onEnded: endDrag)
            }
            // slot + xl equals a row's icon + lg, so the query starts where the row titles do.
            headerGutter(width: metrics.spacing.xl)
            // One structural position: a field inside a branch loses first responder when it flips.
            headerField(prompt: prompt, accessory: accessory, hidden: hidesField)
            if let accessory {
                accessory.view
                // Given room last: at the default priority it would split it with the field.
                Spacer(minLength: 0).layoutPriority(-1)
            }
            if tabOpensChat(accessory) {
                headerGutter(width: metrics.spacing.md)
                quickAITabHint
            }
            if !isCollapsed { headerControls(screen) }
            // Compact pins favorites beside the field; expanded shows them as rows.
            if isCollapsed, settings.showFavoritesInCompactMode,
                let launcher = screen as? LauncherScreen
            {
                let favorites = launcher.compactFavorites
                if !favorites.isEmpty {
                    headerGutter(width: metrics.spacing.md)
                    CompactFavoritesRow(
                        favorites: favorites,
                        showsOverflow: launcher.hasUnshownFavorites,
                        onLaunch: { core.launcherCoordinator.launch($0) },
                        onOverflow: { core.paletteCoordinator.expandFromCompact() }
                    )
                }
            }
            headerGutter(width: metrics.spacing.md * 2)
        }
        // Identical metrics in both states, so typing can't move the search bar.
        .frame(height: metrics.size.headerHeight)
        .padding(.top, metrics.size.headerPadding)
        .frame(maxWidth: .infinity)
        // Set after the show, so the field it names is focused rather than the search field.
        .onChange(of: vm.pendingArgumentEntryID) { focusPendingArgument() }
        .onChange(of: argumentFocused) { _, field in vm.noteEditingField(field != nil) }
        .onChange(of: quickAI.pendingAttachments.map(\.id)) { refreshAttachmentsMenu() }
    }

    /// Keyed off the mode, which says which screen is up; the field just flexes narrower.
    @ViewBuilder
    private func headerControls(_ screen: any PaletteScreen) -> some View {
        switch vm.mode {
        case .clipboard:
            headerGutter(width: metrics.spacing.md)
            ClipboardFilterButton(
                filter: vm.clipboardFilter, isOpen: openMenu == .clipboardFilter,
                action: { toggleFilter(.clipboardFilter, \.clipboardFilter) })
        case .fileSearch:
            headerGutter(width: metrics.spacing.md)
            HeaderMenuButton(
                title: vm.fileSearchFilter.title, systemImage: vm.fileSearchFilter.systemImage,
                isOpen: openMenu == .fileSearchFilter, help: "Filter by type  ⌘P",
                action: { toggleFilter(.fileSearchFilter, \.fileSearchFilter) })
        case .emoji:
            headerGutter(width: metrics.spacing.md)
            HeaderMenuButton(
                title: vm.emojiCategoryFilter.title, systemImage: vm.emojiCategoryFilter.systemImage,
                isOpen: openMenu == .emojiCategory, help: "Filter by category  ⌘P",
                action: { toggleFilter(.emojiCategory, \.emojiCategoryFilter) })
        case .ai:
            headerGutter(width: metrics.spacing.md)
            AIModelButton(
                title: core.aiChatCoordinator.selectedModelTitle(for: quickAI),
                icon: core.aiChatCoordinator.selectedModelIcon(for: quickAI),
                isOpen: openMenu == .aiModel, action: toggleAIModel)
            if !core.aiChatCoordinator.reasoningEfforts(for: quickAI).isEmpty {
                headerGutter(width: metrics.spacing.md)
                AIReasoningButton(
                    title: core.aiChatCoordinator.selectedReasoningTitle(for: quickAI),
                    isOpen: openMenu == .aiReasoning, action: toggleAIReasoning)
            }
        case .extensionCommand:
            if let command = screen as? ExtensionCommandScreen, let accessory = command.searchAccessory {
                headerGutter(width: metrics.spacing.md)
                command.searchAccessoryButton(
                    accessory, isOpen: openMenu == .extensionAccessory,
                    action: toggleExtensionSearchAccessory)
            }
        default:
            EmptyView()
        }
    }

    /// Nothing else advertises Tab, so the launcher says where it goes.
    private var quickAITabHint: some View {
        BarButton(chrome: .rounded, action: cycleMode) {
            HStack(spacing: metrics.spacing.sm) {
                Text("Quick AI")
                    .font(metrics.typography.bar)
                    .foregroundStyle(Theme.Colors.textSecondary)
                KeyCapChip(text: "⇥", style: .outline)
            }
        }
        .help("Ask Quick AI what you typed  ⇥")
    }

    /// Resolved through `PaletteTabAction`, so the hint cannot promise the wrong destination.
    private func tabOpensChat(_ accessory: PaletteHeaderAccessory?) -> Bool {
        guard !isCollapsed, accessory?.fieldNames.isEmpty ?? true else { return false }
        return PaletteTabAction.resolve(
            mode: vm.mode, aiEnabled: settings.aiEnabled,
            clipboardEnabled: settings.clipboardEnabled) == .ask
    }

    /// Kept mounted and hidden rather than swapped: a branch would tear its editor down.
    private func headerField(
        prompt: String, accessory: PaletteHeaderAccessory?, hidden: Bool
    ) -> some View {
        // Fixed only where something shares the row: the accessory strip, or a screen's own title.
        let width = hidden ? nil : accessory.map { searchFieldWidth(for: $0, prompt: prompt) }
        return searchField(prompt: prompt, hidden: hidden)
            // A ceiling, not a size, so the row squeezes a long query before the strip overruns.
            .frame(minWidth: width.map { min($0, metrics.size.searchFieldMinWidth) }, maxWidth: width)
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            // The frame it publishes is where the panel puts an I-beam; hidden, it owns nowhere.
            .onChange(of: hidden) { _, hidden in
                if hidden { vm.searchFieldFrame = .zero }
            }
    }

    /// The field's own text (or the prompt), floored for the caret and capped so the strip fits.
    private func searchFieldWidth(for accessory: PaletteHeaderAccessory, prompt: String) -> CGFloat {
        let font = metrics.typography.searchFieldNSFont
        let text = vm.query.isEmpty ? prompt : vm.query
        let typed = (text as NSString).size(withAttributes: [.font: font]).width
        let chrome = metrics.size.headerIconSlot + metrics.spacing.md * 3 + metrics.spacing.xl
        let room = metrics.size.panelWidth - accessory.width - chrome
        // +3pt so the caret sits after the last glyph rather than on top of it.
        return min(
            max(typed + metrics.scaled(3), metrics.scaled(18)),
            max(room, metrics.size.searchFieldMinWidth))
    }

    private func searchPrompt(
        _ screen: any PaletteScreen, accessory: PaletteHeaderAccessory?
    ) -> String {
        // Squeezed to the caret, the field has no room for a prompt; beside one it keeps it.
        if accessory?.placement == .afterQuery, vm.mode != .ai { return "" }
        if let command = screen as? ExtensionCommandScreen,
            let placeholder = command.screen.searchPlaceholder
        {
            return placeholder
        }
        return vm.mode.placeholder
    }

    /// The one search field — empty it's a drag handle, and any text hands every press to editing.
    private func searchField(prompt: String, hidden: Bool) -> some View {
        @Bindable var vm = vm
        return TextField("", text: $vm.query)
            .textFieldStyle(.plain)
            .font(metrics.typography.searchField)
            .tint(Theme.Colors.textPrimary)
            .focused($searchFocused)
            // Fills the row's height, so there's no gap above it for topDragStrip to meet.
            .frame(maxHeight: .infinity)
            .background(alignment: .leading) {
                // An IME's marked text leaves `query` empty, so the placeholder would overlap it.
                if vm.query.isEmpty, !vm.isComposing {
                    Text(prompt)
                        .font(metrics.typography.searchField)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                        // Never a click target: tapping the placeholder must still land the caret.
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(Text(prompt))
            // Never branches on query — that tore down the field editor mid-keystroke once.
            .overlay {
                if settings.paletteDraggable {
                    EmptyFieldDragHandle(
                        isEmpty: vm.query.isEmpty && !vm.isComposing,
                        onBegan: beginDrag, onEnded: endDrag,
                        // A press that never moved was aimed at the field the handle covers.
                        onClick: { searchFocused = true })
                }
            }
            // The panel resolves the pointer against this rather than hit-testing for the field.
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                vm.searchFieldFrame = hidden ? .zero : $0
            }
    }

    /// Floating controls, no bar; the edge dissolve ghosts the rows passing beneath.
    func bottomBar(pillLabel: String, showActionGroup: Bool, showActions: Bool) -> some View {
        HStack(spacing: 0) {
            MenuCircleButton {
                if openMenu == .app { closeMenus() } else { open(.app, highlighting: 0) }
            }
            .modifier(ExtensionToastSlot(extensions: extensions, showing: vm.mode == .extensionCommand))
            Spacer()
            if showActionGroup {
                actionGroup(pillLabel: pillLabel, showActions: showActions)
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .frame(height: metrics.size.bottomBarHeight)
        .frame(maxWidth: .infinity)
    }

    /// The primary action and the Actions toggle sharing one glass capsule.
    private func actionGroup(pillLabel: String, showActions: Bool) -> some View {
        HStack(spacing: 2) {
            BarButton(action: activateSelection) {
                HStack(spacing: metrics.spacing.sm) {
                    Text(pillLabel)
                        .font(metrics.typography.bar)
                        // The Uninstall screen's primary action is destructive, so its pill isn't white.
                        .foregroundStyle(vm.mode == .uninstall ? Theme.Colors.destructive : .primary)
                    keyCaps(isExtensionForm ? ["⌘", "↵"] : ["↵"])
                }
            }
            if showActions {
                BarButton(action: toggleActions) {
                    HStack(spacing: metrics.spacing.sm) {
                        Text("Actions")
                            .font(metrics.typography.bar)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        keyCaps(["⌘", "K"])
                    }
                }
            }
        }
        .padding(metrics.spacing.xs)
        .frosted(in: Capsule())
    }

    private func keyCaps(_ keys: [String]) -> some View {
        HStack(spacing: metrics.spacing.xxs) {
            ForEach(keys, id: \.self) { KeyCapChip(text: $0, style: .outline) }
        }
    }

    /// An extension keeps its own stack, so it can have a step back the palette cannot see.
    private var hasBackStep: Bool {
        vm.canGoBack || (vm.mode == .extensionCommand && extensions.navigationDepth > 1)
    }

    /// Never promises a step the click does not take: a root screen closes rather than backs.
    private var backHelp: String {
        let escape = hasBackStep ? "Esc to go back" : "Esc to close"
        return "\(escape) or ⌘ Esc to go to root search"
    }
}

/// The footer's menu circle; hover lives here, so a sweep never re-renders the body.
private struct MenuCircleButton: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.metrics) private var metrics

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Capsule().frame(width: 14, height: 1.5)
                Capsule().frame(width: 8, height: 1.5)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(width: metrics.size.menuButton, height: metrics.size.menuButton)
            .background(Circle().fill(hovered ? Theme.Colors.rowHover : Color.clear))
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .frosted(in: Circle())
    }
}

/// Hover state lives here, so lighting the chevron never re-renders the header around it.
private struct HeaderBackButton: View {
    let help: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.metrics) private var metrics

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(metrics.typography.headerIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                .frame(width: metrics.size.headerIconSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: Theme.Duration.hover), value: hovered)
        .help(help)
    }
}

import AppKit

/// Owns layouts: the library, the one run funnel with its gate, capture, and a deletion's cleanup.
@MainActor
final class WindowLayoutCoordinator {
    private let store: WindowLayoutStore
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let references: WindowLibraryReferenceService
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    /// Dialog and message-HUD presentation, and the editor handoff. Never state this type owns.
    private unowned let core: AppCore
    /// One run at a time: a held shortcut must not stack two passes over the same windows.
    private var run: Task<Void, Never>?

    init(
        store: WindowLayoutStore, settings: AppSettings, appIndex: AppIndex,
        hotKeys: HotKeyManager, favorites: FavoritesStore, visibility: VisibilityStore,
        ranking: LauncherRankingStore, aliases: AliasStore,
        paletteCoordinator: PaletteCoordinator, settingsCoordinator: SettingsCoordinator,
        core: AppCore
    ) {
        self.store = store
        self.settings = settings
        self.appIndex = appIndex
        references = WindowLibraryReferenceService(
            hotKeys: hotKeys, favorites: favorites, visibility: visibility, ranking: ranking,
            aliases: aliases)
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.core = core
    }

    func applyWindowLayoutsPresence() {
        let visible = settings.windowManagementEnabled && settings.windowLayoutsShowInLauncher
        appIndex.setWindowLayouts(visible ? store.layouts : [])
        let commands: Set<CommandID> = [.createWindowLayout, .captureWindowLayout]
        appIndex.setCommandsVisible(commands, settings.windowManagementEnabled)
        appIndex.setCommandsListed(commands, settings.windowLayoutsShowInLauncher)
    }

    /// The one funnel for a palette row, a global shortcut and the pane's Apply alike.
    func runWindowLayout(id: UUID) {
        guard settings.windowManagementEnabled, let layout = store.layout(id: id) else { return }
        // Never restoreFocus: an opened app activates itself, and handing focus back races that.
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        let gap = CGFloat(settings.windowGap)
        run?.cancel()
        run = Task { [weak self] in
            let outcome = await WindowLayoutRunner.run(layout, gap: gap)
            await self?.report(outcome, for: layout)
        }
    }

    func prepareForTermination() {
        run?.cancel()
        run = nil
    }

    @discardableResult
    func addWindowLayout(_ draft: WindowLayout) throws(WindowLayoutValidationError) -> WindowLayout {
        try store.add(draft)
    }

    func updateWindowLayout(_ draft: WindowLayout) throws(WindowLayoutValidationError) {
        try store.update(draft)
    }

    func duplicateWindowLayout(id: UUID) {
        do {
            _ = try store.duplicate(id: id)
        } catch {
            Task {
                await core.showNotice(
                    title: "Couldn't Save the Layout",
                    message: error.errorDescription ?? "The layout could not be saved.",
                    symbol: WindowLayout.sfSymbol, tone: .danger)
            }
        }
    }

    func deleteWindowLayout(id: UUID) {
        guard let layout = store.remove(id: id) else { return }
        references.remove([layout], action: HotKeyAction.windowLayout)
    }

    @discardableResult
    func replaceWindowLayouts(_ incoming: [WindowLayout]) -> Int {
        let previous = store.layouts
        let count = store.replace(with: incoming)
        references.removeDropped(from: previous, keeping: store.layouts, action: HotKeyAction.windowLayout)
        return count
    }

    /// Opens the Window Management pane with the editor showing `layout`; nil is a new one.
    func editWindowLayout(_ layout: WindowLayout?) {
        core.pendingWindowLayoutEdit = WindowLayoutEditRequest(layout: layout)
        settingsCoordinator.showSettings(tab: .windowManagement)
    }

    /// Capture never saves silently: the draft lands in the editor so it can be seen and named.
    func captureWindowLayout() {
        let (entries, frontmostEntryID) = WindowLayoutRunner.captureCurrentWindows()
        guard !entries.isEmpty else {
            core.showMessage("No windows to capture", tone: .neutral)
            return
        }
        // Gapless by construction, so a later change to `windowGap` can't move every window.
        let draft = WindowLayout(
            name: WindowLayoutStore.uniqueName("Captured Layout", among: store.layouts),
            usesPreferredGap: false,
            entries: entries, frontmostEntryID: frontmostEntryID)
        core.pendingWindowLayoutEdit = WindowLayoutEditRequest(layout: draft, isCapture: true)
        settingsCoordinator.showSettings(tab: .windowManagement)
    }

    private func report(_ outcome: WindowLayoutRunner.Outcome, for layout: WindowLayout) async {
        if outcome.isBlockedOnPermission {
            let openSettings = await core.reportFailure(
                title: "Tinycast Needs Accessibility Access",
                message: "Arranging windows uses the same permission as pasting.",
                symbol: layout.symbol, recovery: "Open Settings")
            if openSettings { Permissions.openAccessibilitySettings() }
            return
        }
        // Placing windows is its own feedback, so a clean run says nothing at all.
        guard let detail = detail(for: outcome) else { return }
        guard outcome.didAnything else {
            await core.showNotice(
                title: "Couldn't Run “\(layout.name)”", message: detail, symbol: layout.symbol,
                tone: .danger)
            return
        }
        core.showMessage("\(layout.name) — \(detail)", tone: .neutral)
    }

    /// What went wrong, or nil when everything the layout asked for happened.
    private func detail(for outcome: WindowLayoutRunner.Outcome) -> String? {
        var parts: [String] = []
        if let skipped = WindowLayoutPlan(placements: [], skipped: outcome.skipped).skippedSummary {
            parts.append(skipped)
        }
        if !outcome.neverAppeared.isEmpty {
            let count = outcome.neverAppeared.count
            parts.append(count == 1 ? "1 app didn't open" : "\(count) apps didn't open")
        }
        let failed = outcome.openFailures.count
        if failed > 0 {
            parts.append(failed == 1 ? "1 app couldn't open" : "\(failed) apps couldn't open")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

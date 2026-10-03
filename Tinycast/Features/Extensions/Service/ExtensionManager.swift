import AppKit
import Foundation

/// What the palette is showing for the running command.
enum ExtensionSessionState: Equatable {
    case idle
    case launching
    case rendered(RenderTree)
    case failed(String)
    /// A no-view command that ran to completion.
    case finished
}

/// Owns the installed set, the runtime and the running command.
@MainActor
@Observable
final class ExtensionManager: ExtensionRuntimeDelegate, ExtensionHostContext {
    private(set) var installed: [InstalledExtension] = []
    /// The store's newer version of each installed extension that has one, keyed by manifest name.
    private(set) var updates: [String: ExtensionListing] = [:]
    private(set) var updating: Set<String> = []
    private(set) var state: ExtensionSessionState = .idle
    private(set) var running: ExtensionCommandRef?
    /// Newest last.
    private(set) var toasts: [ExtensionToast] = []
    /// Depth of the extension's own navigation stack; >1 means Escape should pop rather than close.
    private(set) var navigationDepth = 1
    /// Each search-bar dropdown's choice, keyed by node so a pushed screen keeps its own.
    private(set) var accessoryValues: [Int: String] = [:]
    /// Off means nothing scanned, published or held: the feature costs an unused stored property.
    private(set) var isEnabled = false
    /// Whether the commands reach the launcher at all; independent of `isEnabled`.
    private(set) var showsInLauncher = true
    private var menuBars: ExtensionMenuBarManager?

    var isAuthorizing: Bool { oauthSession.isAuthorizing }

    let storage: ExtensionStorage
    let appearances = ExtensionAppearanceStore()
    let commandMetadata = ExtensionCommandMetadataStore(fileURL: ExtensionCatalog.commandMetadataFile())
    private let storeVersions = ExtensionVersionStore(fileURL: ExtensionCatalog.storeVersionsFile())
    @ObservationIgnored let runtime: ExtensionRuntime
    @ObservationIgnored private let bridge: ExtensionHostBridge
    @ObservationIgnored let oauthSession = ExtensionOAuthSession()
    @ObservationIgnored private weak var appIndex: AppIndex?
    @ObservationIgnored private(set) weak var coordinator: ExtensionCoordinator?

    /// The entry ids an uninstall invalidated, so another feature can drop what it keyed to them.
    @ObservationIgnored var onDidUninstall: (([String]) -> Void)?

    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored var backgroundSessionID: String?
    @ObservationIgnored var backgroundRef: ExtensionCommandRef?
    @ObservationIgnored var backgroundContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored var backgroundFailure: String?
    @ObservationIgnored var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var nextToastID = 1
    @ObservationIgnored var lastOAuthExtensionName: String?

    init(clipboardStore: ClipboardStore) {
        storage = ExtensionStorage(directory: ExtensionCatalog.storageDirectory())
        bridge = ExtensionHostBridge(clipboardStore: clipboardStore)
        runtime = ExtensionRuntime(hostAPI: bridge)
        bridge.context = self
    }

    /// Wires collaborators only; the coordinator decides whether anything scans.
    func start(appIndex: AppIndex, coordinator: ExtensionCoordinator) {
        self.appIndex = appIndex
        self.coordinator = coordinator
        runtime.setDelegate(self)
        // Not gated on `isEnabled`: a stranded workspace is ours whether or not the feature is on.
        let temp = FileManager.default.temporaryDirectory
        Task.detached(priority: .utility) { ExtensionCleanup.sweepWorkspaces(in: temp) }
    }

    // MARK: - The switches

    /// Idempotent both ways, so launch and the switch are the same call.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard enabled else {
            menuBars?.stop()
            menuBars = nil
            await stop()
            backgroundTask?.cancel()
            backgroundTask = nil
            installed = []
            appIndex?.setExtensionCommands([])
            return
        }
        if let coordinator { menuBars = makeMenuBars(coordinator: coordinator) }
        await refresh()
        ensureBackgroundLoop()
    }

    private func makeMenuBars(coordinator: ExtensionCoordinator) -> ExtensionMenuBarManager {
        ExtensionMenuBarManager(
            storage: storage,
            commandMetadata: commandMetadata,
            supportDirectory: ExtensionCatalog.supportRoot(),
            makeExecution: { [weak self, weak coordinator] owner, command, type in
                guard let self, let coordinator else { return nil }
                let host = ExtensionMenuBarHost(
                    owner: owner, command: command, launchType: type, storage: storage,
                    manager: self, coordinator: coordinator)
                let bridge = self.bridge.scoped(to: host)
                return .init(
                    runtime: ExtensionRuntime(
                        hostAPI: bridge, priority: type == .background ? .utility : .userInitiated),
                    stop: {
                        host.stop()
                        bridge.context = nil
                    }, enableInteraction: { host.enableInteraction() })
            },
            onError: { [weak coordinator] message, owner, needsPreferences in
                coordinator?.showHUD(message)
                if needsPreferences { coordinator?.showExtensionSettings(for: owner) }
            })
    }

    func setShowsInLauncher(_ shows: Bool) {
        guard shows != showsInLauncher else { return }
        showsInLauncher = shows
        publishLauncherEntries()
    }

    /// Switching one on runs it: the item it draws is whatever that run renders.
    func setMenuBarEnabled(_ enabled: Bool, reference: ExtensionCommandRef) {
        guard enabled else {
            menuBars?.disable(reference.entryID)
            return
        }
        guard let owner = extensionNamed(reference.extensionName),
            let command = owner.command(named: reference.commandName)
        else { return }
        menuBars?.run(owner, command: command)
    }

    // MARK: - Installed set

    func refresh() async {
        guard isEnabled else { return }
        let found = await Task.detached(priority: .utility) { ExtensionCatalog.scan() }.value
        guard isEnabled else { return }
        if found != installed {
            installed = found
            publishLauncherEntries()
            restartBackgroundLoop()
        }
        menuBars?.synchronize(found)
    }

    func extensionNamed(_ name: String) -> InstalledExtension? {
        installed.first { $0.manifest.name == name }
    }

    /// Built from the installed set, not `AppIndex`: a shortcut can fire before a row ever exists.
    func launcherEntry(forEntryID entryID: String) -> AppEntry? {
        resolve(entryID: entryID).map { entry(for: $1, in: $0) }
    }

    func publishLauncherEntries() {
        guard isEnabled, showsInLauncher else {
            appIndex?.setExtensionCommands([])
            return
        }
        let entries = installed
            .flatMap { owner in owner.manifest.commands.map { entry(for: $0, in: owner) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        appIndex?.setExtensionCommands(entries)
    }

    func entry(for command: ExtensionCommand, in owner: InstalledExtension) -> AppEntry {
        let reference = owner.reference(for: command)
        let info = metadata(reference)
        // A dropped `interval` retires the dot with it, however stale the stored flag is.
        let schedulable = ExtensionRefreshPolicy.isSchedulable(
            mode: command.mode, interval: command.interval)
        return AppEntry(
            id: reference.entryID,
            name: command.title,
            url: owner.directory,
            bundleID: nil,
            kind: .extensionCommand,
            subtitle: ExtensionRefreshPolicy.displaySubtitle(
                manifest: command.subtitle, override: info.subtitle, ownerTitle: owner.title),
            backgroundRefresh: ExtensionRefreshPolicy.indicator(
                schedulable: schedulable, backgroundEnabled: info.backgroundEnabled,
                lastError: info.lastError),
            keywords: command.keywords,
            iconOverride: icon(for: command, in: owner),
            ownerName: owner.title, installedAt: owner.installedAt)
    }

    func metadata(_ reference: ExtensionCommandRef) -> ExtensionCommandMetadata {
        commandMetadata.metadata(extension: reference.extensionName, command: reference.commandName)
    }

    /// Persist and re-publish, so rows change under the user rather than on the next scan.
    func setAppearance(_ appearance: ExtensionAppearance?, for extensionName: String) {
        appearances.set(appearance, for: extensionName)
        publishLauncherEntries()
    }

    /// A chosen appearance wins over the command's artwork, then the extension's.
    private func icon(for command: ExtensionCommand, in owner: InstalledExtension) -> EntryIcon {
        if let appearance = appearances.appearance(for: owner.manifest.name) {
            return .tintedSymbol(name: appearance.symbol, tint: appearance.tint.symbolTint)
        }
        let commandIcon = command.icon.map {
            owner.directory.appendingPathComponent("assets").appendingPathComponent($0).path
        }.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        guard let path = commandIcon ?? owner.iconPath else { return .symbol("puzzlepiece.extension") }
        return .artwork(path: path, extent: ExtensionIconCache.extent)
    }

    // MARK: - Install / uninstall

    func install(from source: URL) async throws {
        untrack(try ExtensionCatalog.install(from: source).manifest.name)
        await refresh()
    }

    /// Scanned off-main: it reads a manifest per directory, and a full Raycast install is dozens.
    func raycastImportCandidates() async -> [RaycastImportCandidate] {
        let candidates = await Task.detached(priority: .userInitiated) {
            ExtensionCatalog.importableFromRaycast()
        }.value
        let have = Set(installed.map(\.manifest.name))
        return candidates.map {
            RaycastImportCandidate(installed: $0, isInstalled: have.contains($0.manifest.name))
        }
    }

    func install(
        _ listing: ExtensionListing,
        onProgress: @Sendable @escaping (ExtensionInstaller.Progress) -> Void
    ) async throws {
        try await installFromStore(listing, onProgress: onProgress)
        await refresh()
    }

    /// Progress is reported per step: building from source can take minutes.
    @discardableResult
    func install(
        _ source: ExtensionGitHubSource, packageManager: ExtensionPackageManager,
        additionalSearchPaths: [String],
        onProgress: @Sendable @escaping (ExtensionInstaller.Progress) -> Void
    ) async throws -> InstalledExtension {
        let installer = ExtensionInstaller(
            packageManager: packageManager, additionalSearchPaths: additionalSearchPaths)
        let installed = try await installer.install(source, onProgress: onProgress)
        untrack(installed.manifest.name)
        await refresh()
        return installed
    }

    /// Refreshes once at the end, and returns what failed so the pane can name it.
    @discardableResult
    func importAllFromRaycast(
        _ candidates: [InstalledExtension], onProgress: (Int) -> Void = { _ in }
    ) async -> [String] {
        var failed: [String] = []
        for (index, candidate) in candidates.enumerated() {
            do {
                let name = try ExtensionCatalog.install(from: candidate.directory).manifest.name
                storeVersions.record(nil, for: name)
                updates[name] = nil
            } catch {
                failed.append(candidate.title)
            }
            onProgress(index + 1)
        }
        await refresh()
        return failed
    }

    // MARK: - Updates

    /// Asked when Settings opens; a lookup that fails is skipped rather than reported.
    func checkForUpdates() async {
        guard isEnabled else { return }
        let tracked = storeVersions.tracked
        let lookups = installed.map(\.manifest).filter { tracked.contains($0.name) }
        let client = ExtensionStoreClient()
        let latest = await withTaskGroup(of: ExtensionListing?.self) { group in
            for manifest in lookups {
                let (handle, name) = (manifest.storeHandle, manifest.name)
                group.addTask { try? await client.lookup(handle: handle, name: name) }
            }
            var found: [ExtensionListing] = []
            for await listing in group {
                if let listing { found.append(listing) }
            }
            return found
        }
        guard !Task.isCancelled else { return }
        updates = Dictionary(
            storeVersions.reconcile(with: latest).map { ($0.name, $0) }, uniquingKeysWith: { $1 })
    }

    /// One at a time, like an import; returns the titles that failed so the pane can name them.
    func update(_ names: [String]) async -> [String] {
        updating.formUnion(names)
        var failed: [String] = []
        for name in names {
            defer { updating.remove(name) }
            guard let listing = updates[name] else { continue }
            do {
                try await installFromStore(listing, onProgress: { _ in })
            } catch {
                failed.append(listing.title)
            }
        }
        await refresh()
        return failed
    }

    /// Replaces only the extension's directory, so its preferences and storage carry over.
    private func installFromStore(
        _ listing: ExtensionListing,
        onProgress: @Sendable @escaping (ExtensionInstaller.Progress) -> Void
    ) async throws {
        let installed = try await ExtensionInstaller().install(listing, onProgress: onProgress)
        storeVersions.record(listing.commitSHA, for: installed.manifest.name)
        updates[installed.manifest.name] = nil
    }

    /// A folder or GitHub install is the user's own copy, so the store has nothing to offer it.
    private func untrack(_ name: String) {
        storeVersions.forget(name)
        updates[name] = nil
    }

    /// Takes everything keyed to it: files, storage, icon, and its shortcuts.
    func uninstall(_ installedExtension: InstalledExtension) async {
        let name = installedExtension.manifest.name
        menuBars?.remove(extensionName: name)
        if running?.extensionName == name { await stop() }
        if backgroundRef?.extensionName == name { await abortBackgroundRun() }
        let entryIDs = installedExtension.manifest.commands.map {
            installedExtension.reference(for: $0).entryID
        }
        ExtensionOAuthKeychain.removeAllTokens(extensionName: name)
        try? ExtensionCatalog.uninstall(installedExtension)
        storage.removeAll(extension: name)
        commandMetadata.removeAll(extension: name)
        untrack(name)
        appearances.set(nil, for: name)
        onDidUninstall?(entryIDs)
        await refresh()
    }

    // MARK: - Running a command

    /// Resolve a launcher row to a command, or nil when the row isn't an extension command.
    func resolve(_ entry: AppEntry) -> (InstalledExtension, ExtensionCommand)? {
        resolve(entryID: entry.id)
    }

    private func resolve(entryID: String) -> (InstalledExtension, ExtensionCommand)? {
        guard let reference = ExtensionCommandRef(entryID: entryID),
            let owner = extensionNamed(reference.extensionName),
            let command = owner.command(named: reference.commandName)
        else { return nil }
        return (owner, command)
    }

    /// A deep link names owner/extension/command; the owner is a hint, the slug decides.
    func resolve(_ link: ExtensionDeepLink) -> (InstalledExtension, ExtensionCommand)? {
        let candidates = installed.filter { link.matches(manifestName: $0.manifest.name) }
        guard
            let owner = link.extensionCandidates.lazy.compactMap({ want in
                candidates.first { $0.manifest.name.lowercased() == want.lowercased() }
            }).first ?? candidates.first,
            let command = owner.manifest.commands.first(where: {
                $0.name.lowercased() == link.commandName.lowercased()
            })
        else { return nil }
        return (owner, command)
    }

    func run(
        _ owner: InstalledExtension, command: ExtensionCommand, arguments: [String: String] = [:],
        fallbackText: String? = nil, launchType: ExtensionLaunchType = .userInitiated,
        launchContext: [String: RenderValue] = [:]
    ) async {
        guard isEnabled else { return }
        if command.mode == .menuBar || (command.mode == .noView && launchType == .background) {
            menuBars?.run(
                owner, command: command, arguments: arguments, type: launchType, context: launchContext)
            return
        }
        await stop()
        guard isEnabled else { return }
        running = owner.reference(for: command)
        let missing = storage.missingRequiredPreferences(
            extension: owner.manifest.name, schemas: owner.manifest.preferences + command.preferences)
        guard missing.isEmpty else {
            state = .failed(ExtensionLaunchError.missingPreferences(missing).localizedDescription)
            return
        }
        guard let bundle = owner.bundleURL(for: command) else {
            state = .failed(ExtensionLaunchError.notBuilt(command.title).localizedDescription)
            return
        }
        navigationDepth = 1
        state = .launching

        // The runtime holds one context: a background tick in flight yields to the manual run.
        await abortBackgroundRun()

        // Raycast activates the schedule on first manual open; the run itself is the first refresh.
        if ExtensionRefreshPolicy.isSchedulable(mode: command.mode, interval: command.interval) {
            commandMetadata.activateBackgroundRefresh(
                extension: owner.manifest.name, command: command.name, now: Date())
            restartBackgroundLoop()
        }

        let supportPath = ExtensionCatalog.supportPath(for: owner.manifest.name)
        try? FileManager.default.createDirectory(at: supportPath, withIntermediateDirectories: true)
        do {
            // No-op while a context is already up; after `stop()` this builds a fresh one.
            try await runtime.boot(config: .current(supportDirectory: supportPath))
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let code = await Self.readBundle(bundle, priority: .userInitiated)
        guard !code.isEmpty else {
            state = .failed(ExtensionLaunchError.notBuilt(command.title).localizedDescription)
            return
        }

        let session = UUID().uuidString
        sessionID = session
        let context = makeLaunchContext(
            owner: owner, command: command, arguments: arguments, supportPath: supportPath,
            fallbackText: fallbackText,
            launchType: command.mode == .view ? .userInitiated : launchType,
            launchContext: launchContext)
        await runtime.start(
            session: session, code: code, file: bundle, mode: command.mode, context: context)
    }

    /// A bundle is a few hundred KB, so the read stays off the main actor.
    nonisolated static func readBundle(_ bundle: URL, priority: TaskPriority) async -> String {
        await Task.detached(priority: priority) {
            (try? String(contentsOf: bundle, encoding: .utf8)) ?? ""
        }.value
    }

    func makeLaunchContext(
        owner: InstalledExtension, command: ExtensionCommand, arguments: [String: String],
        supportPath: URL, fallbackText: String? = nil, launchType: ExtensionLaunchType,
        launchContext: [String: RenderValue] = [:]
    ) -> ExtensionLaunchContext {
        ExtensionLaunchContext(
            extensionName: owner.manifest.name,
            extensionTitle: owner.title,
            commandName: command.name,
            commandMode: command.mode,
            assetsPath: owner.assetsPath,
            supportPath: supportPath.path,
            preferences: storage.resolvedPreferences(
                extension: owner.manifest.name,
                schemas: owner.manifest.preferences + command.preferences),
            caches: storage.caches(extension: owner.manifest.name),
            arguments: command.completeArguments(arguments),
            fallbackText: fallbackText,
            launchType: launchType,
            isDarkAppearance: NSApp.effectiveAppearance.isDark,
            launchContext: launchContext)
    }

    func stop() async {
        oauthSession.cancel()
        if let sessionID {
            self.sessionID = nil
            await runtime.stop(session: sessionID)
            // Discard the context outright, so nothing left behind reaches the next run.
            runtime.shutdown()
            storage.flush()
        }
        state = .idle
        running = nil
        toasts = []
        navigationDepth = 1
        accessoryValues = [:]
    }

    // MARK: - Events from the palette

    func dispatch(handler: String, arguments: [Any] = []) {
        guard let sessionID else { return }
        let payload = ExtensionRuntime.jsonString(from: arguments)
        Task { await runtime.dispatch(session: sessionID, handler: handler, payload: payload) }
    }

    /// What the dropdown shows: the extension's own `value` when it controls one, else the pick.
    func accessorySelection(_ accessory: ExtensionSearchAccessory) -> String? {
        accessory.controlledValue ?? accessoryValues[accessory.nodeID]
    }

    /// A pick persists where the dropdown asked it to, then tells the extension.
    func chooseAccessorySelection(_ accessory: ExtensionSearchAccessory, value: String) {
        accessoryValues[accessory.nodeID] = value
        if let key = accessory.storageKey, let name = running?.extensionName {
            storage.setAccessoryValue(extension: name, key: key, value: value)
        }
        if let handler = accessory.onChange { dispatch(handler: handler, arguments: [value]) }
    }

    /// Raycast reports a dropdown's opening choice through `onChange`; a filtering extension waits on it.
    private func seedSearchBarAccessory(in tree: RenderTree) {
        guard
            let accessory = ExtensionSearchAccessory(
                node: tree.activeRoot?.node("searchBarAccessory")),
            accessory.controlledValue == nil, accessoryValues[accessory.nodeID] == nil,
            let value = accessory.initialValue(stored: storedAccessoryValue(accessory))
        else { return }
        accessoryValues[accessory.nodeID] = value
        if let handler = accessory.onChange { dispatch(handler: handler, arguments: [value]) }
    }

    private func storedAccessoryValue(_ accessory: ExtensionSearchAccessory) -> String? {
        guard let key = accessory.storageKey, let name = running?.extensionName else { return nil }
        return storage.accessoryValue(extension: name, key: key)
    }

    /// Pops the extension's stack; false when there is nothing to pop and the palette should close.
    func popNavigation() async -> Bool {
        guard let sessionID, navigationDepth > 1 else { return false }
        return await runtime.popNavigation(session: sessionID)
    }

    func runToastAction(token: String) {
        Task { await runtime.runToastAction(token: token) }
    }

    // MARK: - Toasts

    func present(toast: ExtensionToast) -> Int {
        var stamped = toast
        stamped.id = nextToastID
        nextToastID += 1
        // A no-view command's toast has no palette to appear in, so show a HUD.
        guard coordinator?.isPaletteVisible == true else {
            coordinator?.showHUD(
                [toast.title, toast.message].compactMap { $0 }.joined(separator: " — "))
            return stamped.id
        }
        toasts = [stamped]
        scheduleToastDismissal(stamped)
        return stamped.id
    }

    func update(toast id: Int, with toast: ExtensionToast) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        var stamped = toast
        stamped.id = id
        toasts[index] = stamped
        scheduleToastDismissal(stamped)
    }

    func hide(toast id: Int) {
        toasts.removeAll { $0.id == id }
    }

    /// An animated toast stays until the command hides it.
    private func scheduleToastDismissal(_ toast: ExtensionToast) {
        guard toast.style != .animated else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.hide(toast: toast.id)
        }
    }

    // MARK: - ExtensionRuntimeDelegate

    func runtime(_ runtime: ExtensionRuntime, session: String, didRender tree: RenderTree) {
        guard session == sessionID else { return }
        state = .rendered(tree)
        navigationDepth = tree.depth
        seedSearchBarAccessory(in: tree)
    }

    func runtime(_ runtime: ExtensionRuntime, session: String, didFail message: String) {
        if session == backgroundSessionID {
            backgroundFailure = message
            resumeBackground(with: false)
        } else if session == sessionID {
            state = .failed(message)
        }
    }

    func runtime(_ runtime: ExtensionRuntime, session: String, navigationDepth depth: Int) {
        guard session == sessionID else { return }
        navigationDepth = depth
    }

    func runtime(_ runtime: ExtensionRuntime, session: String, didFinish: Void) {
        if session == backgroundSessionID {
            resumeBackground(with: true)
        } else if session == sessionID {
            // The palette is already closing, so just release the session.
            state = .finished
            Task { await stop() }
        }
    }

    func runtime(_ runtime: ExtensionRuntime, log level: String, message: String) {
        #if DEBUG
            print("[extension \(level)] \(message)")
        #endif
    }
}

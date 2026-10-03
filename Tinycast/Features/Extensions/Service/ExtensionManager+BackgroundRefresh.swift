import Foundation

/// Background refresh: headless `no-view` runs on the manifest's `interval`, sharing the one runtime.
extension ExtensionManager {
    func backgroundInfo(extension name: String, command: String) -> ExtensionCommandMetadata {
        commandMetadata.metadata(extension: name, command: command)
    }

    func setBackgroundEnabled(_ enabled: Bool, extension name: String, command: String) {
        commandMetadata.setBackgroundEnabled(enabled, extension: name, command: command)
        if !enabled { commandMetadata.clearBackgroundError(extension: name, command: command) }
        publishLauncherEntries()
        restartBackgroundLoop()
    }

    func menuBarIsEnabled(_ reference: ExtensionCommandRef) -> Bool {
        metadata(reference).menuBarEnabled
    }

    /// Whether the Actions menu can offer refresh controls for this row.
    func isBackgroundSchedulable(for entry: AppEntry) -> Bool {
        guard let (_, command) = resolve(entry) else { return false }
        return ExtensionRefreshPolicy.isSchedulable(mode: command.mode, interval: command.interval)
    }

    func isBackgroundEnabled(for entry: AppEntry) -> Bool {
        guard let reference = ExtensionCommandRef(entryID: entry.id) else { return false }
        return metadata(reference).backgroundEnabled
    }

    func toggleBackgroundRefresh(for entry: AppEntry) {
        guard let reference = ExtensionCommandRef(entryID: entry.id),
            isBackgroundSchedulable(for: entry)
        else { return }
        setBackgroundEnabled(
            !metadata(reference).backgroundEnabled, extension: reference.extensionName,
            command: reference.commandName)
    }

    /// One headless run right now, without touching the enable flag or the palette.
    func refreshNow(_ entry: AppEntry) {
        guard let (owner, command) = resolve(entry),
            ExtensionRefreshPolicy.isSchedulable(mode: command.mode, interval: command.interval),
            running == nil, backgroundSessionID == nil
        else { return }
        Task { [weak self] in
            await self?.runInBackground(owner, command: command)
            self?.restartBackgroundLoop()
        }
    }

    /// With nothing enabled there is no task at all, so an unused schedule costs nothing.
    func ensureBackgroundLoop() {
        guard isEnabled, backgroundTask == nil, !scheduledCommands(now: Date()).isEmpty else { return }
        backgroundTask = Task { [weak self] in await self?.backgroundLoop() }
    }

    func restartBackgroundLoop() {
        backgroundTask?.cancel()
        backgroundTask = nil
        ensureBackgroundLoop()
    }

    private func backgroundLoop() async {
        try? await Task.sleep(for: .seconds(5))
        while !Task.isCancelled {
            guard isEnabled else { return }
            await runDueBackgroundCommands()
            if Task.isCancelled { return }
            // The last schedule going away stops the loop itself; enabling restarts it.
            guard !scheduledCommands(now: Date()).isEmpty else {
                backgroundTask = nil
                return
            }
            try? await Task.sleep(for: .seconds(nextBackgroundDelay()))
        }
    }

    /// Every enabled schedulable command, with when it is next due.
    private func scheduledCommands(
        now: Date
    ) -> [(owner: InstalledExtension, command: ExtensionCommand, due: Date)] {
        installed.flatMap { owner in
            owner.manifest.commands.compactMap { command in
                guard
                    ExtensionRefreshPolicy.isSchedulable(mode: command.mode, interval: command.interval),
                    let interval = command.interval
                else { return nil }
                let reference = owner.reference(for: command)
                let info = metadata(reference)
                guard info.backgroundEnabled else { return nil }
                let due = ExtensionRefreshPolicy.nextDue(
                    lastRun: info.lastRun, now: now, interval: interval,
                    consecutiveFailures: info.consecutiveFailures, entryID: reference.entryID)
                return (owner, command, due)
            }
        }
    }

    /// Due commands within one window fire as a batch, so close ticks share a single wakeup.
    private func runDueBackgroundCommands() async {
        guard running == nil, backgroundSessionID == nil else { return }
        let now = Date()
        let horizon = now.addingTimeInterval(ExtensionRefreshPolicy.coalescingWindow)
        for (owner, command, due) in scheduledCommands(now: now) where due <= horizon {
            guard !Task.isCancelled, isEnabled, running == nil else { break }
            await runInBackground(owner, command: command)
        }
    }

    /// Capped, so an install or a toggle surfaces without anyone restarting the loop.
    private func nextBackgroundDelay() -> TimeInterval {
        guard running == nil else { return ExtensionRefreshPolicy.coalescingWindow }
        let now = Date()
        return scheduledCommands(now: now).reduce(ExtensionRefreshPolicy.idleHeartbeat) {
            min($0, max($1.due.timeIntervalSince(now), 5))
        }
    }

    /// The palette never moves and no feedback fires; only the subtitle can change.
    private func runInBackground(_ owner: InstalledExtension, command: ExtensionCommand) async {
        guard backgroundSessionID == nil, running == nil, let interval = command.interval,
            let bundle = owner.bundleURL(for: command)
        else { return }
        let reference = owner.reference(for: command)
        let supportPath = ExtensionCatalog.supportPath(for: owner.manifest.name)
        try? FileManager.default.createDirectory(at: supportPath, withIntermediateDirectories: true)

        let session = UUID().uuidString
        backgroundSessionID = session
        backgroundRef = reference
        backgroundFailure = nil
        var succeeded = false
        defer {
            // Gone mid-run means uninstalled: recording would resurrect its storage file.
            if extensionNamed(reference.extensionName) != nil {
                commandMetadata.recordBackgroundResult(
                    extension: reference.extensionName, command: reference.commandName,
                    success: succeeded, error: succeeded ? nil : (backgroundFailure ?? "Timed out."),
                    now: Date())
            }
            backgroundSessionID = nil
            backgroundRef = nil
            backgroundFailure = nil
            backgroundContinuation = nil
            publishLauncherEntries()
            storage.flush()
            commandMetadata.flush()
        }

        do {
            try await runtime.boot(config: .current(supportDirectory: supportPath))
        } catch {
            backgroundFailure = error.localizedDescription
            return
        }
        let code = await Self.readBundle(bundle, priority: .utility)
        guard !code.isEmpty else {
            backgroundFailure = ExtensionLaunchError.notBuilt(command.title).localizedDescription
            return
        }
        let context = makeLaunchContext(
            owner: owner, command: command, arguments: [:], supportPath: supportPath,
            launchType: .background)
        await runtime.start(
            session: session, code: code, file: bundle, mode: command.mode, context: context)
        succeeded = await waitForBackgroundResult(
            timeout: ExtensionRefreshPolicy.timeout(interval: interval))
        // An abort already tore the session down; stopping here would kill the manual run's context.
        guard backgroundSessionID == session else { return }
        await runtime.stop(session: session)
        runtime.shutdown()
    }

    private func waitForBackgroundResult(timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { [weak self] in await self?.backgroundSettled() ?? false }
            group.addTask { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    // Cancelling the loop preempts the tick; only a real timeout is a failure.
                    await self?.resumeBackground(with: true)
                    return true
                }
                await self?.resumeBackground(with: false)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    /// Suspends until the run settles, times out, or is preempted; `resumeBackground` is every exit.
    private func backgroundSettled() async -> Bool {
        await withCheckedContinuation { backgroundContinuation = $0 }
    }

    /// Ends the in-flight background run as a success so its schedule survives the preemption.
    func abortBackgroundRun() async {
        guard let session = backgroundSessionID else { return }
        backgroundSessionID = nil
        backgroundRef = nil
        await runtime.stop(session: session)
        runtime.shutdown()
        resumeBackground(with: true)
    }

    /// Main-actor serial, so no two exits can resume the same continuation.
    func resumeBackground(with result: Bool) {
        guard let continuation = backgroundContinuation else { return }
        backgroundContinuation = nil
        continuation.resume(returning: result)
    }
}

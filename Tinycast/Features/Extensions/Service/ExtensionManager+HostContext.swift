import AppKit

/// What a running command's API calls reach, through `ExtensionHostBridge`.
extension ExtensionManager {
    var activeExtensionName: String? { backgroundRef?.extensionName ?? running?.extensionName }
    var activeLaunchType: ExtensionLaunchType {
        backgroundSessionID != nil ? .background : .userInitiated
    }
    var pasteTarget: NSRunningApplication? { coordinator?.pasteTarget }
    var applicationURLs: [URL] { coordinator?.applicationURLs ?? [] }

    func closeMainWindow(clearRootSearch: Bool) { coordinator?.closeMainWindow() }
    func reopenPalette() { coordinator?.reopenPalette(hasRunningCommand: running != nil) }
    func popToRoot() { coordinator?.popExtensionToRoot() }
    func clearSearchBar() { coordinator?.clearSearchBar() }
    func showHUD(_ text: String) { coordinator?.showHUD(text) }

    func openPreferences(scope: String) {
        guard let running, let owner = extensionNamed(running.extensionName) else { return }
        coordinator?.showExtensionSettings(for: owner)
    }

    /// The running command's row metadata; a missing key leaves the subtitle alone.
    func updateCommandMetadata(subtitle: String?) {
        guard let reference = backgroundRef ?? running else { return }
        updateCommandMetadata(subtitle: subtitle, for: reference)
    }

    func updateCommandMetadata(subtitle: String?, for reference: ExtensionCommandRef) {
        commandMetadata.setSubtitle(
            subtitle, extension: reference.extensionName, command: reference.commandName)
        publishLauncherEntries()
    }

    func confirmAlert(_ alert: ExtensionAlert) async -> Bool {
        await coordinator?.confirmExtensionAlert(alert) ?? false
    }

    func openWithPicker(path: String) async {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: target)
        guard candidates.count > 1 else {
            NSWorkspace.shared.open(target)
            return
        }
        let panel = NSAlert()
        panel.messageText = "Open With"
        panel.informativeText = target.lastPathComponent
        for candidate in candidates.prefix(4) {
            panel.addButton(withTitle: candidate.deletingPathExtension().lastPathComponent)
        }
        panel.addButton(withTitle: "Cancel")
        let response = panel.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard response >= 0, response < min(candidates.count, 4) else { return }
        NSWorkspace.shared.open(
            [target], withApplicationAt: candidates[Int(response)],
            configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// `launchCommand` from a running command: same extension unless it names another.
    func launch(
        command name: String, extensionName: String?, arguments: [String: String],
        fallbackText: String?, launchType: ExtensionLaunchType, launchContext: [String: RenderValue]
    ) throws {
        guard let owningName = extensionName ?? activeExtensionName,
            let owner = extensionNamed(owningName), let command = owner.command(named: name)
        else { throw ExtensionLaunchError.unknownCommand(name) }
        guard isEnabled else { throw ExtensionLaunchError.unsupported("Extensions are disabled.") }
        guard launchType != .background || command.mode != .view else {
            throw ExtensionLaunchError.unsupported("A view command cannot run in the background.")
        }
        coordinator?.runExtensionCommand(
            entry(for: command, in: owner), arguments: arguments, fallbackText: fallbackText,
            launchType: launchType, launchContext: launchContext)
    }

    func launch(_ link: ExtensionDeepLink) throws {
        guard let (owner, command) = resolve(link) else {
            throw ExtensionLaunchError.unknownCommand(link.commandName)
        }
        coordinator?.runExtensionCommand(
            entry(for: command, in: owner), arguments: link.arguments,
            fallbackText: link.fallbackText, launchType: link.launchType)
    }

    func authorizeOAuth(
        options: ExtensionOAuthAuthorizeOptions
    ) async throws -> ExtensionOAuthAuthorizeResult {
        lastOAuthExtensionName = running?.extensionName
        return try await oauthSession.authorize(options: options)
    }

    private var oauthExtensionName: String? { running?.extensionName ?? lastOAuthExtensionName }

    func getOAuthTokens(providerId: String) -> String? {
        guard let name = oauthExtensionName else { return nil }
        return ExtensionOAuthKeychain.getTokens(extensionName: name, providerId: providerId)
    }

    func setOAuthTokens(providerId: String, tokens: String) {
        guard let name = oauthExtensionName else { return }
        ExtensionOAuthKeychain.setTokens(tokens, extensionName: name, providerId: providerId)
    }

    func removeOAuthTokens(providerId: String) {
        guard let name = oauthExtensionName else { return }
        ExtensionOAuthKeychain.removeTokens(extensionName: name, providerId: providerId)
    }
}

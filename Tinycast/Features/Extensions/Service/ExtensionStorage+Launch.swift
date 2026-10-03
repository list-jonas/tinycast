import AppKit

/// What every launch reads from storage, so the palette, background and menu bar boot alike.
extension ExtensionStorage {
    /// A command with an unset required preference must not run.
    func missingRequiredPreferences(
        owner: InstalledExtension, command: ExtensionCommand
    ) -> [ExtensionPreferenceSchema] {
        let name = owner.manifest.name
        return (owner.manifest.preferences + command.preferences).filter { schema in
            guard schema.required else { return false }
            let value = preference(extension: name, key: schema.name) ?? schema.effectiveDefault
            if case .string(let text) = value { return text.isEmpty }
            return false
        }
    }

    /// Preferences are manifest defaults overlaid with the user's: what `getPreferenceValues()` sees.
    func launchContext(
        owner: InstalledExtension, command: ExtensionCommand, arguments: [String: String],
        supportPath: URL, fallbackText: String? = nil, launchType: ExtensionLaunchType,
        launchContext: [String: RenderValue] = [:]
    ) -> ExtensionLaunchContext {
        let name = owner.manifest.name
        var preferences: [String: ExtensionPreferenceValue] = [:]
        for schema in owner.manifest.preferences + command.preferences {
            preferences[schema.name] = schema.runtimeValue(preference(extension: name, key: schema.name))
        }
        return ExtensionLaunchContext(
            extensionName: name, extensionTitle: owner.title, commandName: command.name,
            commandMode: command.mode, assetsPath: owner.assetsPath, supportPath: supportPath.path,
            preferences: preferences, caches: caches(extension: name),
            arguments: command.completeArguments(arguments), fallbackText: fallbackText,
            launchType: launchType, isDarkAppearance: NSApp.effectiveAppearance.isDark,
            launchContext: launchContext)
    }
}

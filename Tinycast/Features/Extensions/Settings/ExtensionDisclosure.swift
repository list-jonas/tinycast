import SwiftUI

/// A summary row, and while open its settings on an inset card — separators and fill, never glass.
struct ExtensionDisclosure: View {
    let installed: InstalledExtension
    let isExpanded: Bool
    let isUpdating: Bool
    let onToggle: () -> Void
    /// Nil unless the store has a newer version.
    let onUpdate: (() -> Void)?
    let onUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isExpanded {
                settings
                    .padding(.top, Theme.Spacing.lg)
            }
        }
    }

    private var summary: some View {
        SettingsRow(title: installed.title, subtitle: subtitle) {
            ExtensionIconView(resolved: installed.resolvedIcon, size: Theme.Size.rowIcon)
        } trailing: {
            if isUpdating {
                ProgressView().controlSize(.small)
            } else if let onUpdate {
                Button("Update", action: onUpdate)
            }
            Button(action: onUninstall) {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.Colors.destructive)
            }
            .buttonStyle(.plain)
            .help("Uninstall")
            .accessibilityLabel("Uninstall \(installed.title)")
            Image(systemName: "chevron.down")
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        // The whole row toggles: a `DisclosureGroup` would only respond to its chevron.
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isExpanded ? "Hide \(installed.title) settings" : "Configure \(installed.title)")
        .id(SettingsTarget.row(.extensionsInstalled, installed.manifest.name))
    }

    /// One `Grid` for every run: separate grids size columns apart, stranding controls.
    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: Theme.Spacing.md) {
            // No heading: these two are one idea, and first so 19 commands can't bury them.
            ExtensionLauncherRow(installed: installed)
            ExtensionIconRow(installed: installed)

            if !installed.manifest.preferences.isEmpty {
                rule
                heading("Preferences")
                ForEach(Array(installed.manifest.preferences.enumerated()), id: \.element.name) {
                    index, schema in
                    if index > 0 { rule }
                    ExtensionPreferenceRow(extensionName: installed.manifest.name, schema: schema)
                }
            }

            rule
            heading(installed.manifest.commands.count == 1 ? "Command" : "Commands")
            ForEach(Array(installed.manifest.commands.enumerated()), id: \.element.id) {
                index, command in
                if index > 0 { rule }
                ExtensionCommandRows(installed: installed, command: command)
            }
        }
        // Indented under the row's icon, so the settings read as belonging to the row above them.
        .padding(.leading, Theme.Size.rowIcon + Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A step below the pane's section headers; nothing here sets a heading in caps.
    private func heading(_ title: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .gridCellColumns(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Spacing.xs)
        }
    }

    /// The hairline every other multi-row group in the app puts between its rows.
    private var rule: some View {
        GridRow {
            Divider()
                .gridCellColumns(2)
        }
    }

    private var subtitle: String {
        let author = installed.manifest.author
        return author.isEmpty ? installed.commandsLabel : "\(installed.commandsLabel) · \(author)"
    }
}

/// One command: alias, shortcut and launcher checkbox on the title row, then its own preferences.
private struct ExtensionCommandRows: View {
    let installed: InstalledExtension
    let command: ExtensionCommand
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(VisibilityStore.self) private var visibility

    var body: some View {
        let entry = installed.launcherEntry(for: command)
        let isVisible = visibility.isItemVisible(entry)
        let reference = installed.reference(for: command)
        // A fact about the command, so it sits by the name as a badge rather than a warning colour.
        ExtensionSettingsCardRow(
            title: command.title, detail: command.description,
            badge: command.mode == .menuBar ? "Menu Bar" : nil, controlWidth: nil
        ) {
            HStack(spacing: Theme.Spacing.lg) {
                // Hidden or unpublished commands never reach rank, so typing here would match nothing.
                AliasField(entry: entry)
                    .settingsEnabled(settings.extensionsShowInLauncher && isVisible)
                // Per command, not per extension: a shortcut has to land on one thing to run.
                ShortcutRecorder(action: .extensionCommand(entryID: entry.id))
                Toggle(
                    "", isOn: Binding(get: { isVisible }, set: { visibility.setItemVisible($0, for: entry) })
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Show in launcher")
                .accessibilityLabel("Show \(command.title) in launcher")
            }
        }
        if command.mode == .menuBar {
            ExtensionSettingsCardRow(title: "Show in menu bar", indent: Theme.Spacing.lg) {
                Toggle(
                    "Show in menu bar",
                    isOn: Binding(
                        get: { core.extensions.menuBarIsEnabled(reference) },
                        set: { core.extensions.setMenuBarEnabled($0, reference: reference) })
                )
                .labelsHidden()
            }
        }
        // Indented under its command: at the same inset the association is reading order.
        ForEach(command.preferences, id: \.name) { schema in
            ExtensionPreferenceRow(
                extensionName: installed.manifest.name, schema: schema, indent: Theme.Spacing.lg)
        }
        // The same predicate the scheduler runs on: an unparseable interval gets no toggle.
        if ExtensionRefreshPolicy.isSchedulable(mode: command.mode, interval: command.interval),
            let schedule = command.intervalRaw
        {
            ExtensionRefreshRow(extensionName: installed.manifest.name, command: command, schedule: schedule)
        }
    }
}

/// One `no-view` command's background refresh: Raycast's interval preference, stored locally.
private struct ExtensionRefreshRow: View {
    let extensionName: String
    let command: ExtensionCommand
    let schedule: String
    @Environment(AppCore.self) private var core

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        let info = core.extensions.commandMetadata.metadata(extension: extensionName, command: command.name)
        ExtensionSettingsCardRow(
            title: "Background refresh", detail: detail(for: info), indent: Theme.Spacing.lg
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { info.backgroundEnabled },
                    set: {
                        core.extensions.setBackgroundEnabled(
                            $0, extension: extensionName, command: command.name)
                    })
            )
            .labelsHidden()
        }
    }

    private func detail(for info: ExtensionCommandMetadata) -> String {
        var detail = "Every \(schedule)."
        if let lastRun = info.lastRun {
            detail += " Last refresh \(Self.relative.localizedString(for: lastRun, relativeTo: Date()))."
        } else {
            detail += " Hasn't refreshed yet."
        }
        if let error = info.lastError {
            detail += " Last error: \(ExtensionRefreshPolicy.headline(error))."
        }
        return detail
    }
}

/// Hides one extension's commands: an import can add hundreds, and the global switch is too blunt.
private struct ExtensionLauncherRow: View {
    let installed: InstalledExtension
    @Environment(VisibilityStore.self) private var visibility

    var body: some View {
        let entries = installed.manifest.commands.map(installed.launcherEntry)
        let visible = entries.count(where: visibility.isItemVisible)
        let detail: String? = switch visible {
        case 0: "Hidden. Shortcuts still work."
        case entries.count: nil
        default: "\(visible) of \(entries.count) commands."
        }
        ExtensionSettingsCardRow(title: "Show in launcher", detail: detail) {
            // A closure, not `set: setVisible`: an actor-isolated method as a setter crashes IRGen.
            Toggle(
                "",
                isOn: Binding(
                    get: { visible > 0 },
                    set: { isOn in entries.forEach { visibility.setItemVisible(isOn, for: $0) } })
            )
            .labelsHidden()
        }
    }
}

/// The launcher icon, and the picker that replaces it.
private struct ExtensionIconRow: View {
    let installed: InstalledExtension
    @Environment(AppCore.self) private var core
    @State private var picking = false

    /// From the store, not the manager: picking publishes there, so both observe it.
    private var appearance: ExtensionAppearance? {
        core.extensions.appearances.appearance(for: installed.manifest.name)
    }

    var body: some View {
        ExtensionSettingsCardRow(title: "Launcher icon", detail: appearance == nil ? nil : "Custom icon.") {
            HStack(spacing: Theme.Spacing.md) {
                if let appearance {
                    SymbolTile(symbol: appearance.symbol, tint: appearance.tint, side: Theme.Size.rowIcon)
                } else {
                    ExtensionIconView(resolved: installed.resolvedIcon, size: Theme.Size.rowIcon)
                }
                Button("Change…") { picking = true }
                    .popover(isPresented: $picking, arrowEdge: .bottom) {
                        ExtensionAppearancePicker(
                            current: appearance ?? .fallback,
                            isCustom: appearance != nil,
                            onPick: { core.extensions.setAppearance($0, for: installed.manifest.name) },
                            onReset: { core.extensions.setAppearance(nil, for: installed.manifest.name) })
                    }
            }
        }
    }
}

extension InstalledExtension {
    var resolvedIcon: ExtensionImage.Resolved? {
        iconPath.map { ExtensionImage.Resolved(source: .file($0)) }
    }

    var commandsLabel: String {
        "\(manifest.commands.count) command\(manifest.commands.count == 1 ? "" : "s")"
    }

    /// The entry `VisibilityStore` and `AliasStore` key on: only its id is read, never its row.
    fileprivate func launcherEntry(for command: ExtensionCommand) -> AppEntry {
        AppEntry(
            id: reference(for: command).entryID, name: command.title, url: directory, bundleID: nil,
            kind: .extensionCommand)
    }
}

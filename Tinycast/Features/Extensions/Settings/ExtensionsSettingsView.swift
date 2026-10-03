import SwiftUI

/// Settings › Extensions: the master switch, then a row per extension that expands in place.
struct ExtensionsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(SettingsNavigationState.self) private var navigation
    @State private var expanded: String?
    @State private var filter = ""
    @State private var importCandidates: RaycastImportCandidates?
    @State private var browsingStore = false
    @State private var installingFromGitHub = false
    @State private var error: String?
    @State private var updateError: String?
    /// Extensions Raycast has built that aren't here yet, refreshed whenever the pane appears.
    @State private var pending: [RaycastImportCandidate] = []
    /// What a bulk import is doing, so a thirty-item batch reports rather than going quiet.
    @State private var importProgress: (done: Int, total: Int)?
    @State private var importSummary: String?
    /// What a cleanup would reclaim, rescanned whenever the installed set changes.
    @State private var reclaimable = ExtensionCleanup.Report()

    private var extensions: ExtensionManager { core.extensions }

    var body: some View {
        @Bindable var settings = core.settings
        return Form {
            FeatureSwitchSection(
                anchor: .extensionsExtensions,
                enableTitle: "Enable extensions",
                enableSubtitle: "Run Raycast extensions natively.",
                // Enabling is consent to run third-party code, so the setter confirms.
                isEnabled: Binding(
                    get: { settings.extensionsEnabled },
                    set: { core.extensionCoordinator.setExtensionsEnabled($0) }),
                showsInLauncher: $settings.extensionsShowInLauncher,
                showsIcon: true)

            Group {
                install
                library
                compatibility
            }
            .settingsEnabled(settings.extensionsEnabled)

            // Outside the enabled group: leftovers are on disk whether or not extensions are on.
            storage
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.extensions)
        .releasesFocusOnOutsideClick()
        // Escape and Return are the keyboard way out of the same field.
        .onExitCommand { NSApp.keyWindow?.makeFirstResponder(nil) }
        .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
        // By item: `isPresented` builds the panel from a snapshot taken before the write.
        .settingsEditorPanel(item: $importCandidates) { candidates in
            ExtensionImportPanel(
                candidates: candidates.entries,
                onImport: { chosen in
                    importCandidates = nil
                    Task { await importAll(chosen) }
                },
                onCancel: { importCandidates = nil })
        }
        .settingsEditorPanel(isPresented: $browsingStore) {
            ExtensionStorePanel(onClose: { browsingStore = false })
        }
        .settingsEditorPanel(isPresented: $installingFromGitHub) {
            ExtensionGitHubPanel(onClose: { installingFromGitHub = false })
        }
        .onChange(of: navigation.scrollRequest, initial: true) {
            if case .row(.extensionsInstalled, let name)? = navigation.scrollRequest?.target {
                (expanded, filter) = (name, "")
            }
        }
        .onChange(of: extensions.installed.count) { Task { await measureReclaimable() } }
        .task {
            await extensions.refresh()
            await measureReclaimable()
            await findPending()
            await extensions.checkForUpdates()
        }
    }

    private func row<Trailing: View>(
        _ title: String, _ subtitle: String, symbol: String, anchor: SettingsAnchor? = nil,
        subtitleLineLimit: Int = 1, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        SettingsRow(
            title: title, subtitle: subtitle, subtitleLineLimit: subtitleLineLimit, anchor: anchor
        ) {
            Image(systemName: symbol)
                .font(.system(size: Theme.Size.settingsRowIcon - Theme.Spacing.xs))
                .foregroundStyle(.primary)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
        } trailing: {
            trailing()
        }
    }

    @ViewBuilder
    private func warning(_ message: String?) -> some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var compatibility: some View {
        Section {
            row(
                "What works",
                "List, detail, form, grid, no-view and menu-bar commands, plus preferences, storage and OAuth.",
                symbol: "checkmark.circle", subtitleLineLimit: 2) {}
            row(
                "What doesn't, yet", "Raycast's OAuth proxy, and its AI, browser and window services.",
                symbol: "xmark.circle", subtitleLineLimit: 2) {}
        } header: {
            SettingsSectionHeader(.extensionsCompatibility)
        }
    }

    // MARK: - The library

    private var library: some View {
        Section {
            if !extensions.updates.isEmpty {
                // Above the list as well as on each row, so a batch is one press.
                row(
                    "Updates available", listed(extensions.updates.values.map(\.title)) + ".",
                    symbol: "arrow.down.circle"
                ) {
                    if extensions.updating.isEmpty {
                        Button("Update All") { update(extensions.updates.keys.sorted()) }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if extensions.installed.isEmpty {
                Text("Nothing installed yet.")
                    .foregroundStyle(.secondary)
            } else {
                if extensions.installed.count > 3 {
                    SettingsFilterField(prompt: "Filter extensions…", query: $filter)
                }
                if matching.isEmpty {
                    Text("No extension matches \u{201C}\(filter)\u{201D}.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(matching) { installed in
                        let name = installed.manifest.name
                        ExtensionDisclosure(
                            installed: installed,
                            isExpanded: expanded == name,
                            isUpdating: extensions.updating.contains(name),
                            onToggle: { expanded = expanded == name ? nil : name },
                            onUpdate: extensions.updates[name] == nil ? nil : { update([name]) },
                            onUninstall: { core.extensionCoordinator.confirmUninstall(installed) })
                    }
                }
            }
        } header: {
            SettingsSectionHeader(anchor: .extensionsInstalled) {
                Text(
                    extensions.installed.isEmpty
                        ? "Installed" : "Installed (\(extensions.installed.count))")
            }
        } footer: {
            warning(updateError)
        }
    }

    private func update(_ names: [String]) {
        updateError = nil
        Task {
            let failed = await extensions.update(names)
            if !failed.isEmpty { updateError = "Couldn't update \(failed.joined(separator: ", "))." }
        }
    }

    private var matching: [InstalledExtension] {
        guard !filter.isEmpty else { return extensions.installed }
        return extensions.installed.filter { entry in
            entry.title.localizedCaseInsensitiveContains(filter)
                || entry.manifest.commands.contains { $0.title.localizedCaseInsensitiveContains(filter) }
        }
    }

    /// Rows rather than a menu: each route installs differently.
    private var install: some View {
        Section {
            row(
                "Search extensions", "Ready-built from the Raycast Store.", symbol: "magnifyingglass",
                anchor: .extensionsInstall
            ) {
                Button("Search…") { browsingStore = true }
            }
            row(
                "Install from GitHub", "Builds from source with your package manager.",
                symbol: "hammer", anchor: .extensionsInstall
            ) {
                Button("Install…") { installingFromGitHub = true }
            }
            // A state of this row, not a card: the same job as the button beside it.
            row(
                "Import from Raycast", importSubtitle, symbol: "arrow.down.doc",
                anchor: .extensionsInstall
            ) {
                if importProgress != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Import…", action: openImport)
                        .disabled(!raycastAvailable)
                    if !pending.isEmpty {
                        Button("Import All") { Task { await importAll(pending.map(\.installed)) } }
                    }
                }
            }
            row(
                "Add from folder", "A folder with package.json and built commands.", symbol: "folder",
                anchor: .extensionsInstall
            ) {
                Button("Choose…", action: addFolder)
            }
        } header: {
            SettingsSectionHeader(.extensionsInstall)
        } footer: {
            warning(error)
        }
    }

    /// An install cleans up after itself, so in normal use this row has nothing to offer.
    private var storage: some View {
        Section {
            row(
                "Leftover files", reclaimableSubtitle, symbol: "internaldrive",
                anchor: .extensionsStorage
            ) {
                Button("Clean Up…") {
                    Task {
                        await core.extensionCoordinator.confirmCleanup(reclaimable)
                        await measureReclaimable()
                    }
                }
                .disabled(reclaimable.isEmpty)
            }
        } header: {
            SettingsSectionHeader(.extensionsStorage)
        }
    }

    private var reclaimableSubtitle: String {
        guard !reclaimable.isEmpty else { return "Nothing to clean up." }
        let items = reclaimable.items == 1 ? "1 item" : "\(reclaimable.items) items"
        return "Reclaims \(ExtensionCleanup.formatted(bytes: reclaimable.bytes)) from \(items)."
    }

    /// Off-main: measuring walks a `node_modules`, which is tens of thousands of files.
    private func measureReclaimable() async {
        let installed = Set(extensions.installed.map(\.manifest.name))
        let roots = ExtensionCleanup.defaultRoots()
        reclaimable = await Task.detached(priority: .utility) {
            ExtensionCleanup.reclaimable(installed: installed, in: roots)
        }.value
    }

    private var importSubtitle: String {
        if let importProgress { return "Importing \(importProgress.done) of \(importProgress.total)…" }
        if let importSummary { return importSummary }
        guard raycastAvailable else { return "No Raycast install found in ~/.config." }
        guard !pending.isEmpty else { return "Copies what Raycast has already built." }
        return "\(pending.count) not here yet — \(listed(pending.map(\.installed.title)))."
    }

    /// The first three in list order, then a count, so a long batch still fits one subtitle.
    private func listed(_ titles: [String]) -> String {
        // Sorts on the first letter: "(Basic) Bookmarks" otherwise leads on its bracket.
        func sortKey(_ title: String) -> Substring { title.drop { !$0.isLetter && !$0.isNumber } }
        let sorted = titles.sorted {
            sortKey($0).localizedCaseInsensitiveCompare(sortKey($1)) == .orderedAscending
        }
        let names = sorted.prefix(3).joined(separator: ", ")
        return sorted.count > 3 ? "\(names) and \(sorted.count - 3) more" : names
    }

    private var raycastAvailable: Bool { ExtensionCatalog.raycastExtensionsDirectory() != nil }

    // MARK: - Adding

    private func openImport() {
        Task { importCandidates = RaycastImportCandidates(entries: await extensions.raycastImportCandidates()) }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        Task {
            error = nil
            for url in panel.urls {
                do {
                    try await extensions.install(from: url)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func importAll(_ chosen: [InstalledExtension]) async {
        error = nil
        importSummary = nil
        importProgress = (0, chosen.count)
        let failed = await extensions.importAllFromRaycast(chosen) { done in
            importProgress = (done, chosen.count)
        }
        importProgress = nil
        await findPending()
        let imported = chosen.count - failed.count
        if failed.isEmpty {
            importSummary = "Imported \(imported) extension\(imported == 1 ? "" : "s")."
        } else {
            importSummary = "Imported \(imported); \(failed.count) failed."
            error = "Couldn't import \(failed.joined(separator: ", "))."
        }
    }

    private func findPending() async {
        guard core.settings.extensionsEnabled, raycastAvailable else {
            pending = []
            return
        }
        pending = await extensions.raycastImportCandidates().filter { !$0.isInstalled }
    }
}

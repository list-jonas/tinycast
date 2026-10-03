import SwiftUI

/// The layout library, inside the Window Management pane: layouts belong to window management.
struct WindowLayoutsSection: View {
    let onEdit: (WindowLayout?) -> Void
    let onDelete: (WindowLayout) -> Void

    @Environment(WindowLayoutStore.self) private var store
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @State private var query = ""

    /// Below this a filter row is noise: a layout library is a handful of rows, not four hundred.
    private static let filterThreshold = 6

    var body: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.windowLayoutsShowInLauncher) {
                SettingsRowTitle(.windowManagementLayouts, "Show layouts in launcher")
            }

            if store.layouts.count > Self.filterThreshold {
                SettingsFilterField(prompt: "Search layouts…", query: $query)
            }

            if results.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { layout in
                    WindowLayoutSettingsRow(
                        layout: layout,
                        onEdit: { onEdit(layout) },
                        onDelete: { onDelete(layout) })
                }
            }

            Button {
                onEdit(nil)
            } label: {
                SettingsRowTitle(.windowManagementLayouts, "New Layout")
            }
            Button {
                core.windowLayoutCoordinator.captureWindowLayout()
            } label: {
                SettingsRowTitle(.windowManagementLayouts, "Create Layout from Current Windows")
            }
        } header: {
            SettingsSectionHeader(.windowManagementLayouts)
        }
    }

    private var results: [WindowLayout] {
        guard !query.isEmpty else { return store.layouts }
        return store.layouts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var emptyMessage: String {
        store.layouts.isEmpty
            ? "Save an arrangement, then restore it with one shortcut."
            : "No layout matches “\(query)”."
    }
}

private struct WindowLayoutSettingsRow: View {
    let layout: WindowLayout
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(AppCore.self) private var core

    var body: some View {
        SettingsRow(title: layout.name, subtitle: layout.summary) {
            SymbolImage(name: layout.symbol, size: 13)
        } trailing: {
            ShortcutRecorder(action: .windowLayout(id: layout.id))
            WindowLibraryRowButton(symbol: "play", help: "Run this layout", label: "Run \(layout.name)") {
                core.windowLayoutCoordinator.runWindowLayout(id: layout.id)
            }
            WindowLibraryRowButton(
                symbol: "pencil", help: "Edit", label: "Edit \(layout.name)", action: onEdit)
            WindowLibraryRowButton(
                symbol: "plus.square.on.square", help: "Duplicate", label: "Duplicate \(layout.name)"
            ) { core.windowLayoutCoordinator.duplicateWindowLayout(id: layout.id) }
            WindowLibraryRowButton(
                symbol: "trash", help: "Delete", label: "Delete \(layout.name)", isDestructive: true,
                action: onDelete)
            WindowLibraryVisibilityToggle(entry: AppEntry(layout), name: layout.name)
        }
    }
}

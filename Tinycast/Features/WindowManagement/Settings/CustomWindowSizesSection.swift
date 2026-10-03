import SwiftUI

/// The custom-size library, inside the Window Management pane beside the commands it extends.
struct CustomWindowSizesSection: View {
    let onEdit: (CustomWindowSize?) -> Void

    @Environment(CustomWindowSizeStore.self) private var store
    @Environment(CustomWindowSizeCoordinator.self) private var coordinator

    var body: some View {
        Section {
            ForEach(store.sizes) { size in
                CustomWindowSizeRow(
                    size: size,
                    onEdit: { onEdit(size) },
                    onDelete: { delete(size) })
            }
            Button {
                onEdit(nil)
            } label: {
                SettingsRowTitle(.windowManagementCustomSizes, "New Custom Size")
            }
        } header: {
            SettingsSectionHeader(.windowManagementCustomSizes)
        }
    }

    private func delete(_ size: CustomWindowSize) {
        Task { await coordinator.deleteCustomWindowSize(id: size.id) }
    }
}

private struct CustomWindowSizeRow: View {
    let size: CustomWindowSize
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SettingsRow(title: size.name, subtitle: size.summary) {
            Image(systemName: CustomWindowSize.sfSymbol)
        } trailing: {
            ShortcutRecorder(action: .customWindowSize(id: size.id))
            WindowLibraryRowButton(symbol: "pencil", help: "Edit", label: "Edit \(size.name)", action: onEdit)
            WindowLibraryRowButton(
                symbol: "trash", help: "Delete", label: "Delete \(size.name)", isDestructive: true,
                action: onDelete)
            WindowLibraryVisibilityToggle(entry: AppEntry(size), name: size.name)
        }
    }
}

import SwiftUI

/// A plain glyph button on a command, layout, room or size row.
struct WindowLibraryRowButton: View {
    let symbol: String
    let help: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isDestructive {
                Image(systemName: symbol).foregroundStyle(Theme.Colors.destructive)
            } else {
                Image(systemName: symbol)
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The launcher checkbox every window-management row ends with.
struct WindowLibraryVisibilityToggle: View {
    let entry: AppEntry
    let name: String

    @Environment(VisibilityStore.self) private var visibility

    var body: some View {
        Toggle(
            "",
            isOn: Binding(
                get: { visibility.isItemVisible(entry) },
                set: { visibility.setItemVisible($0, for: entry) })
        )
        .labelsHidden()
        .toggleStyle(.checkbox)
        .launcherVisibilityHelp()
        .accessibilityLabel("Show \(name) in launcher")
    }
}

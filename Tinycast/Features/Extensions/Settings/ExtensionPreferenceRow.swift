import SwiftUI

/// One card row: the label left, the control right, columns aligned by the enclosing `Grid`.
struct ExtensionSettingsCardRow<Control: View>: View {
    let title: String
    var detail: String?
    /// Leading inset for a row that belongs to the row above it, rather than to the run.
    var indent: CGFloat = 0
    /// A short fact about the row, beside its name rather than in the control column.
    var badge: String?
    /// `nil` lets a pair of 120pt fields size themselves; the rest share a 200pt trailing edge.
    var controlWidth: CGFloat? = 200
    @ViewBuilder var control: Control

    var body: some View {
        GridRow(alignment: .center) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(title)
                    if let badge {
                        Text(badge)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Spacing.xs)
                            .padding(.vertical, 1)
                            .background(Theme.Colors.controlSurface, in: .capsule)
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridColumnAlignment(.leading)
            // One width for every control: else a toggle, a pop-up and a field end apart.
            control
                .frame(width: controlWidth, alignment: .trailing)
                .gridColumnAlignment(.trailing)
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

/// One preference control, stored so a command reads it through `getPreferenceValues()`.
struct ExtensionPreferenceRow: View {
    let extensionName: String
    let schema: ExtensionPreferenceSchema
    var indent: CGFloat = 0
    @Environment(AppCore.self) private var core
    @State private var text: String = ""
    @State private var flag: Bool = false

    private var storage: ExtensionStorage { core.extensions.storage }

    var body: some View {
        ExtensionSettingsCardRow(title: schema.displayTitle, detail: detail, indent: indent) {
            control
        }
        .onAppear(perform: load)
    }

    private var detail: String? {
        let description = schema.description ?? ""
        guard schema.required else { return description }
        return description.isEmpty ? "Required." : description + " Required."
    }

    @ViewBuilder
    private var control: some View {
        switch schema.kind {
        case .checkbox:
            Toggle(schema.label ?? "", isOn: $flag)
                .labelsHidden()
                .onChange(of: flag) { _, value in
                    storage.setPreference(extension: extensionName, key: schema.name, value: .bool(value))
                }
        case .dropdown:
            Picker("", selection: $text) {
                ForEach(schema.options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .labelsHidden()
            .onChange(of: text) { _, value in save(value) }
        case .password, .textfield:
            Group {
                if schema.kind == .password {
                    SecureField("", text: $text, prompt: schema.placeholder.map(Text.init))
                } else {
                    TextField("", text: $text, prompt: schema.placeholder.map(Text.init))
                }
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .pointerStyle(.horizontalText)
            .onChange(of: text) { _, value in save(value) }
        case .file, .directory, .appPicker:
            HStack(spacing: Theme.Spacing.sm) {
                Text(text.isEmpty ? "Not set" : (text as NSString).lastPathComponent)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…", action: choosePath)
            }
        }
    }

    private func load() {
        let value = storage.preference(extension: extensionName, key: schema.name) ?? schema.effectiveDefault
        text = value.stringValue
        flag = value.boolValue
    }

    private func save(_ value: String) {
        storage.setPreference(extension: extensionName, key: schema.name, value: .string(value))
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = schema.kind != .directory
        panel.canChooseDirectories = schema.kind == .directory
        if schema.kind == .appPicker {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        text = url.path
        save(url.path)
    }
}

import SwiftUI

/// One candidate from a local Raycast install, and whether we already have it.
struct RaycastImportCandidate: Identifiable {
    let installed: InstalledExtension
    let isInstalled: Bool

    var id: String { installed.id }
}

/// One scan of the local Raycast install, carried as the import panel's presentation item.
struct RaycastImportCandidates: Identifiable {
    let id = UUID()
    let entries: [RaycastImportCandidate]
}

/// Anything not already built starts selected, so the common case is one press.
struct ExtensionImportPanel: View {
    let candidates: [RaycastImportCandidate]
    let onImport: ([InstalledExtension]) -> Void
    let onCancel: () -> Void
    @State private var chosen: Set<String> = []
    @State private var seeded = false
    @State private var filter = ""

    private var fresh: [RaycastImportCandidate] { candidates.filter { !$0.isInstalled } }

    /// Thirty-odd rows is past the point where scanning beats filtering.
    private var matching: [RaycastImportCandidate] {
        guard !filter.isEmpty else { return candidates }
        return candidates.filter { $0.installed.title.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ExtensionSettingsEditorHeader(title: "Import from Raycast", subtitle: subtitle)

            if candidates.count > 6 {
                SettingsFilterField(prompt: "Filter…", query: $filter)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matching) { candidate in
                        // AppKit aligns a checkbox to its label's first baseline.
                        HStack(spacing: Theme.Spacing.md) {
                            Toggle("", isOn: binding(for: candidate))
                                .labelsHidden()
                            ExtensionIconView(
                                resolved: candidate.installed.resolvedIcon, size: Theme.Size.rowIcon)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(candidate.installed.title)
                                Text(
                                    candidate.isInstalled
                                        ? "\(candidate.installed.commandsLabel) · installed — tick to update"
                                        : candidate.installed.commandsLabel
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture { binding(for: candidate).wrappedValue.toggle() }
                    }
                }
                .hideNativeScrollers()
            }
            .overflowFade()
            .thinScrollbar()
            .frame(minHeight: 220)

            HStack {
                // Reads against what is selected, so it is never a button that does nothing.
                Button(allChosen ? "Deselect All" : "Select All") {
                    chosen = allChosen ? [] : Set(candidates.map(\.installed.manifest.name))
                }
                .buttonStyle(ExtensionSettingsEditorButtonStyle(role: .standard, fillsWidth: false))
                .disabled(candidates.isEmpty)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(ExtensionSettingsEditorButtonStyle(role: .cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Import \(chosen.isEmpty ? "" : "(\(chosen.count))")") {
                    onImport(candidates.map(\.installed).filter { chosen.contains($0.manifest.name) })
                }
                .buttonStyle(ExtensionSettingsEditorButtonStyle(role: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .extensionSettingsEditorPanelSurface()
        .onAppear {
            // Once: re-seeding on every render would fight the user's own deselection.
            guard !seeded else { return }
            seeded = true
            chosen = Set(fresh.map(\.installed.manifest.name))
        }
    }

    private var allChosen: Bool { chosen.count == candidates.count }

    private var subtitle: String {
        guard !candidates.isEmpty else {
            return "No built extensions found in ~/.config/raycast/extensions."
        }
        guard !fresh.isEmpty else {
            return "Everything Raycast has built is already here. Import one again to update it."
        }
        let count = fresh.count == 1 ? "one" : "\(fresh.count)"
        return "The \(count) you don't have yet \(fresh.count == 1 ? "is" : "are") already ticked. "
            + "Ticking one you have updates it."
    }

    private func binding(for candidate: RaycastImportCandidate) -> Binding<Bool> {
        let name = candidate.installed.manifest.name
        return Binding(
            get: { chosen.contains(name) },
            set: { isOn in
                if isOn { chosen.insert(name) } else { chosen.remove(name) }
            })
    }
}

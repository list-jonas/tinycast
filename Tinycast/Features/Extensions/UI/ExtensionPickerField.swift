import SwiftUI

/// `Form.Dropdown` and `Form.TagPicker`: one control, typing and caret in the field itself.
struct ExtensionPickerField: View {
    private var form: ExtensionFormMetrics { ExtensionFormMetrics(scale: metrics.scale) }
    @Environment(\.metrics) private var metrics
    let items: [ExtensionPickerItem]
    /// Every value currently held; a dropdown has one, a tag picker any number.
    let chosen: [String]
    let placeholder: String
    /// The field's own title, so the control announces what it is rather than as a chevron.
    let title: String
    /// The field's own explanation, spoken after the state so both are heard.
    let info: String?
    /// Whatever the extension reports wrong with the field, spoken before anything else.
    let error: String?
    let assetsPath: String?
    let allowsMultipleSelection: Bool
    let index: Int?
    @FocusState.Binding var focus: Int?
    let onChange: ([String]) -> Void
    let onSubmit: () -> Void

    @State private var list = ExtensionControlList()
    /// Read from the view, so a resolved icon repaints when the surface flips appearance.
    @Environment(\.isDarkAppearance) private var isDark

    /// What a screen reader hears: the query while searching, else the value held.
    private var announcedValue: String {
        guard list.open, !list.query.isEmpty else { return chosen.isEmpty ? placeholder : label }
        return chosen.isEmpty ? list.query : "\(label), searching \(list.query)"
    }

    /// What the control does, then whatever the extension explains about the field.
    private var hint: String {
        ExtensionFieldHint.spoken(list.open ? "Showing choices" : "Opens a list of choices", error, info)
    }

    /// What the closed control reads as: the chosen titles, or the placeholder.
    private var label: String {
        let titles = chosen.compactMap { value in items.first { $0.value == value }?.title }
        return titles.isEmpty ? placeholder : titles.joined(separator: ", ")
    }

    private var leadingIcon: ExtensionImage.Resolved? {
        guard !allowsMultipleSelection, let value = chosen.first else { return nil }
        let icon = items.first { $0.value == value }?.iconValue
        return ExtensionImage.resolve(icon, assetsPath: assetsPath, isDark: isDark)
    }

    private var matches: [ExtensionPickerItem] {
        let trimmed = list.query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        let needle = FuzzyMatch.Query(trimmed)
        return items.filter { FuzzyMatch.score(needle, candidate: $0.title) != nil }
    }

    private var chosenRow: Int { items.firstIndex { chosen.contains($0.value) } ?? 0 }

    var body: some View {
        // Filtered once per render: a fuzzy pass over hundreds of items is not free.
        let matches = matches
        control.modifier(
            ExtensionControlListBehavior(
                list: $list, index: index, focus: $focus,
                field: allowsMultipleSelection ? .tagPicker : .dropdown,
                // The panel's own height, which the placement rule then seats above or below.
                height: form.popoverHeight(
                    rows: matches.count, hasSearchField: false, headers: matches.headingCount),
                revision: Revision(
                    query: list.query, highlighted: list.highlighted, isDark: isDark,
                    chosen: chosen, items: matches, assetsPath: assetsPath),
                rows: matches.count, initialRow: { chosenRow },
                commit: { choose(matches, at: list.highlighted) }, step: step,
                onSubmit: onSubmit
            ) {
                ExtensionPickerList(
                    items: matches, selection: list.highlighted, chosen: Set(chosen),
                    assetsPath: assetsPath, onSelect: { choose(matches, at: $0) },
                    onHighlight: { list.highlighted = $0 })
            })
    }

    private var control: some View {
        HStack(spacing: metrics.spacing.sm) {
            if let leadingIcon, list.query.isEmpty {
                ExtensionIconView(resolved: leadingIcon, size: 14)
            }
            // While the list is open the control is the search field, caret and all.
            if list.open {
                // A multi-select keeps its chosen values in view while the query is typed.
                if allowsMultipleSelection, !chosen.isEmpty {
                    Text(label)
                        .font(metrics.typography.rowTitle)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    Text("·")
                        .font(metrics.typography.rowTitle)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                ExtensionQueryText(query: list.query, prompt: "Search…", phase: list.typedAt)
            } else {
                Text(label)
                    .font(metrics.typography.rowTitle)
                    .foregroundStyle(chosen.isEmpty ? Theme.Colors.textTertiary : Theme.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.sm)
            ExtensionDisclosureChevron(open: list.open, flipped: list.flipped)
        }
        .extensionFieldChrome(focused: focus == index, open: list.open, hovered: list.hovered)
        .contentShape(Rectangle())
        // Without this the control reads as its chevron: no name, no value, no role.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        // While open the control is a search field, so it announces what is being typed.
        .accessibilityValue(Text(announcedValue))
        .accessibilityHint(Text(hint))
        .accessibilityAddTraits(.isButton)
    }

    /// What the hosted list draws; a change to any of it re-pushes the panel's tree.
    private struct Revision: Equatable {
        let query: String
        let highlighted: Int
        let isDark: Bool
        let chosen: [String]
        let items: [ExtensionPickerItem]
        let assetsPath: String?
    }

    /// Clamped rather than wrapping, so holding an arrow settles at an end like every other list.
    private func step(_ delta: Int) -> KeyPress.Result {
        guard !allowsMultipleSelection, !items.isEmpty else { return .ignored }
        let current = chosenRow
        let next = min(max(current + delta, 0), items.count - 1)
        guard next != current else { return .handled }
        onChange([items[next].value])
        return .handled
    }

    private func choose(_ matches: [ExtensionPickerItem], at index: Int) {
        guard matches.indices.contains(index) else { return }
        let value = matches[index].value
        guard allowsMultipleSelection else {
            onChange([value])
            list.close()
            focus = self.index
            return
        }
        // Multi-select stays open, the way ticking several tags off a list wants to work.
        var next = chosen
        if let existing = next.firstIndex(of: value) {
            next.remove(at: existing)
        } else {
            next.append(value)
        }
        onChange(next)
    }
}

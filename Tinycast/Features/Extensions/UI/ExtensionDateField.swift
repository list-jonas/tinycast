import SwiftUI

/// `Form.DatePicker`: presets plus an expression, typed into the control itself.
struct ExtensionDateField: View {
    private var form: ExtensionFormMetrics { ExtensionFormMetrics(scale: metrics.scale) }
    @Environment(\.metrics) private var metrics
    let node: RenderNode
    let index: Int?
    @FocusState.Binding var focus: Int?
    let onChange: (RenderNode, Any) -> Void
    let onSubmit: () -> Void

    @State private var list = ExtensionControlList()

    /// A `date` picker holds a day; anything else holds a time as well.
    private var includesTime: Bool { node.string("type") != "date" }
    private var value: Date? { node.date("value") }

    private var label: String {
        guard let value else { return "No Date" }
        return ExtensionDateExpression.detail(for: value, calendar: .current, includesTime: includesTime)
    }

    /// What the control does, then whatever the extension explains about the field.
    private var hint: String {
        let state = list.open ? "Showing dates" : "Opens a list of dates"
        let parts = [node.string("error"), node.string("info")]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return ([state] + parts).joined(separator: ". ")
    }

    private var suggestions: [ExtensionDateExpression.Suggestion] {
        ExtensionDateExpression.suggestions(
            query: list.query, now: Date(), calendar: .current, includesTime: includesTime)
    }

    var body: some View {
        let suggestions = suggestions
        control.modifier(
            ExtensionControlListBehavior(
                list: $list, index: index, focus: $focus, field: .datePicker,
                // The panel's own height, which the placement rule then seats above or below.
                height: form.popoverHeight(rows: suggestions.count, hasSearchField: false),
                revision: Revision(
                    query: list.query, highlighted: list.highlighted, suggestions: suggestions),
                rows: suggestions.count, initialRow: { 0 },
                commit: { choose(self.suggestions, at: list.highlighted) },
                // A date has no value to step: its arrows belong to the list or to nothing.
                step: { _ in .ignored },
                onSubmit: onSubmit
            ) {
                ExtensionPickerList(
                    items: suggestions.map {
                        ExtensionPickerItem(value: $0.title, title: $0.title, detail: $0.detail)
                    },
                    selection: list.highlighted, chosen: [], assetsPath: nil,
                    onSelect: { choose(suggestions, at: $0) },
                    onHighlight: { list.highlighted = $0 })
            })
    }

    private var control: some View {
        HStack(spacing: metrics.spacing.sm) {
            Image(systemName: "calendar")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
            // While the list is open the control is the expression field, caret and all.
            if list.open {
                ExtensionQueryText(query: list.query, prompt: "tomorrow at 10am", phase: list.typedAt)
            } else {
                Text(label)
                    .font(metrics.typography.rowTitle)
                    .foregroundStyle(value == nil ? Theme.Colors.textTertiary : Theme.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.sm)
            ExtensionDisclosureChevron(open: list.open, flipped: list.flipped)
        }
        .extensionFieldChrome(focused: focus == index, open: list.open, hovered: list.hovered)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(node.string("title") ?? "Date"))
        // While open the control is an expression field, so it announces what is typed.
        .accessibilityValue(Text(list.open && !list.query.isEmpty ? list.query : label))
        .accessibilityHint(Text(hint))
        .accessibilityAddTraits(.isButton)
    }

    /// What the hosted list draws; a change to any of it re-pushes the panel's tree.
    private struct Revision: Equatable {
        let query: String
        let highlighted: Int
        let suggestions: [ExtensionDateExpression.Suggestion]
    }

    private func choose(_ rows: [ExtensionDateExpression.Suggestion], at index: Int) {
        guard rows.indices.contains(index) else { return }
        if let date = rows[index].date {
            onChange(node, RenderValue.date(date).jsonValue)
        } else {
            onChange(node, NSNull())
        }
        list.close()
        focus = self.index
    }
}

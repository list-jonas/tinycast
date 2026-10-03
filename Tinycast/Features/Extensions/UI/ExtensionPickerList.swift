import SwiftUI

/// The results a picker drops, styled as the ⌘K panel; the control above owns the query.
struct ExtensionPickerList: View {
    private var form: ExtensionFormMetrics { ExtensionFormMetrics(scale: metrics.scale) }
    @Environment(\.metrics) private var metrics
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isDarkAppearance) private var isDark
    /// Read for `hoverHighlightArmed`: a list landing under the pointer must light no row.
    @Environment(PaletteState.self) private var palette
    private var menuListInset: CGFloat { metrics.spacing.md }
    let items: [ExtensionPickerItem]
    let selection: Int
    /// Values already chosen; a single-select picker passes the one it holds.
    let chosen: Set<String>
    let assetsPath: String?
    /// Fixed, never intrinsic, so the list cannot jitter as its rows change.
    var width: CGFloat?
    var searchPlaceholder: String?
    let onSelect: (Int) -> Void
    /// Moves the highlight under the pointer, so mouse and keyboard share one selection.
    let onHighlight: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let searchPlaceholder {
                ExtensionMenuSearchField(
                    placeholder: searchPlaceholder, height: form.popoverRowHeight,
                    verticalOffset: 0)
                Rectangle()
                    .fill(Theme.Colors.separator)
                    // One device pixel, matching the actions panel's hairline.
                    .frame(height: 1 / displayScale)
                    .accessibilityHidden(true)
            }
            list
                .padding(searchPlaceholder == nil ? metrics.spacing.sm : 0)
        }
        .frame(width: width ?? form.controlWidth)
        .glassEffect(
            .regular, in: RoundedRectangle(cornerRadius: metrics.radius.menuPanel, style: .continuous)
        )
    }

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            Text(searchPlaceholder == nil ? "No matches" : "No Results")
                .font(metrics.typography.menuRow)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(
                    height: form.popoverRowHeight,
                    alignment: searchPlaceholder == nil ? .leading : .center
                )
                .padding(searchPlaceholder == nil ? 0 : menuListInset)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: form.popoverRowSpacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if let section = item.section, section != items.section(before: index) {
                                sectionHeader(section)
                            }
                            ExtensionPickerRow(
                                title: item.title,
                                detail: item.detail,
                                icon: ExtensionImage.resolve(
                                    item.iconValue, assetsPath: assetsPath, isDark: isDark),
                                checked: chosen.contains(item.value),
                                selected: index == selection,
                                onActivate: { onSelect(index) }
                            )
                            .id(index)
                            .onHover { if $0, palette.hoverHighlightArmed { onHighlight(index) } }
                        }
                    }
                    .padding(searchPlaceholder == nil ? 0 : menuListInset)
                }
                .frame(
                    height: form.popoverListHeight(rows: items.count, headers: items.headingCount)
                        + (searchPlaceholder == nil ? 0 : menuListInset * 2)
                )
                .scrollBounceBehavior(
                    form.popoverListContentHeight(rows: items.count, headers: items.headingCount)
                        > form.popoverRowsMaxHeight
                        ? .always : .basedOnSize
                )
                // `never`, not `hidden`: hidden still lets AppKit claim the scroller's gutter.
                .scrollIndicators(.never)
                .overflowFade(band: form.popoverFadeBand, includingTop: searchPlaceholder == nil)
                .onChange(of: selection, initial: true) { proxy.scrollTo(selection) }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(metrics.typography.sectionHeader)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, metrics.spacing.lg)
            .frame(height: form.popoverSectionHeaderHeight, alignment: .leading)
    }
}

struct ExtensionMenuSearchField: View {
    let placeholder: String
    let height: CGFloat
    let verticalOffset: CGFloat

    @Environment(PaletteState.self) private var palette
    @Environment(\.metrics) private var metrics
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var palette = palette
        TextField("", text: $palette.menuQuery)
            .textFieldStyle(.plain)
            .font(metrics.typography.menuRow)
            .foregroundStyle(Theme.Colors.textPrimary)
            .tint(Theme.Colors.textPrimary)
            .focused($focused)
            .lineLimit(1)
            .background(alignment: .leading) {
                if palette.menuQuery.isEmpty {
                    Text(placeholder)
                        .font(metrics.typography.menuRow)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, metrics.spacing.xl + metrics.spacing.sm)
            .frame(height: height)
            .offset(y: verticalOffset)
            .padding(.vertical, metrics.spacing.xxs / 2)
            .accessibilityLabel(placeholder)
            .onAppear { focused = true }
    }
}

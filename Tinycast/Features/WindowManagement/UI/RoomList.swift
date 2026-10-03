import SwiftUI

/// Both Rooms screens' list: rows framed by the selection, a tap activates, the palette scrolls.
struct RoomList<Row: Identifiable, Content: View>: View where Row.ID == String {
    @Environment(\.metrics) private var metrics
    let rows: [Row]
    let selectedID: String?
    let scroll: ScrollIntent
    let onActivate: (Row) -> Void
    @ViewBuilder let content: (Row, _ selected: Bool) -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        content(row, row.id == selectedID)
                            .selectionFrame(row.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(row) }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.vertical, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: selectedID != nil && selectedID == rows.first?.id,
                proxy: proxy)
        }
    }
}

/// One row's fill, hover and padding; the row's own label and value go on the result.
struct RoomListRow<Label: View>: View {
    @Environment(\.metrics) private var metrics
    let selected: Bool
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        HStack(spacing: metrics.spacing.lg, content: label)
            .padding(.horizontal, metrics.spacing.md)
            .padding(.vertical, metrics.spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                    .fill(selected ? Theme.Colors.selection : hovered ? Theme.Colors.rowHover : .clear))
            .armedHover($hovered)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

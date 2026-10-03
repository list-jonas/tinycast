import SwiftUI

struct RoomsList: View {
    let rows: [RoomRow]
    let selectedID: RoomRow.ID?
    let scroll: ScrollIntent
    let currentRoomID: UUID?
    let layout: (Room) -> RoomLayoutKind
    let onActivate: (RoomRow) -> Void

    var body: some View {
        RoomList(rows: rows, selectedID: selectedID, scroll: scroll, onActivate: onActivate) { row, selected in
            RoomRowView(
                row: row, selected: selected, isCurrent: row.room?.id == currentRoomID,
                layout: row.room.map(layout))
        }
    }
}

private struct RoomRowView: View {
    @Environment(\.metrics) private var metrics
    let row: RoomRow
    let selected: Bool
    let isCurrent: Bool
    /// Nil for the rows that make or edit a room rather than enter one.
    let layout: RoomLayoutKind?

    private var title: String {
        switch row {
        case .room(let room): room.name
        case .edit(let room): "Choose Windows for “\(room.name)”"
        case .create(let name): "Create Room “\(name)”"
        }
    }

    private var subtitle: String {
        switch row {
        case .room(let room):
            let apps = room.windows.map(\.appName).reduce(into: [String]()) { names, name in
                if !names.contains(name) { names.append(name) }
            }
            return ([isCurrent ? "Current" : nil, room.summary] + [apps.joined(separator: ", ")])
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .edit, .create:
            return "Pick the open windows that belong in it"
        }
    }

    private var symbol: String {
        switch row {
        case .room: Room.sfSymbol
        case .edit: "macwindow.badge.plus"
        case .create: CommandID.createRoom.sfSymbol
        }
    }

    var body: some View {
        RoomListRow(selected: selected) {
            EntryIconView(source: .symbol(symbol))
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(metrics.typography.rowTitle)
                    .lineLimit(1)
                Text(subtitle)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.md)
            if let layout {
                HStack(spacing: metrics.spacing.sm) {
                    Text(layout.title)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(.secondary)
                    // Tab changes the selected room's layout, so only that row advertises it.
                    if selected { KeyCapChip(text: "⇥", style: .outline) }
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(layout.map { "\(subtitle), \($0.title) layout" } ?? subtitle)
    }
}

extension RoomRow {
    fileprivate var room: Room? {
        guard case .room(let room) = self else { return nil }
        return room
    }
}

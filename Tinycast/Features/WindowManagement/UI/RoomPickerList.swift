import SwiftUI

struct RoomPickerList: View {
    let rows: [RoomPickerRow]
    /// Room order; a member's place is its index plus one.
    let picked: [RoomSession.Pick]
    let selectedID: String?
    let scroll: ScrollIntent
    let onActivate: (RoomPickerRow) -> Void

    var body: some View {
        RoomList(
            rows: rows, selectedID: selectedID, scroll: scroll, onActivate: onActivate
        ) { row, selected in
            RoomPickerRowView(
                row: row, place: picked.firstIndex(of: row.pick).map { $0 + 1 }, selected: selected)
        }
    }
}

private struct RoomPickerRowView: View {
    @Environment(\.metrics) private var metrics
    let row: RoomPickerRow
    /// Its place in the room, 1 being the main window; nil when it is not in the room.
    let place: Int?
    let selected: Bool

    private var title: String {
        switch row {
        case .window(let window):
            window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? window.appName : window.title
        case .app(let app):
            app.name
        }
    }

    private var trailing: String {
        switch row {
        case .window(let window):
            if window.isAppHidden { return "\(window.appName) · Hidden" }
            if window.isMinimized { return "\(window.appName) · Minimized" }
            return window.appName
        case .app:
            return "App · Opens with the room"
        }
    }

    private var appURL: URL? {
        switch row {
        case .window(let window): window.appURL
        case .app(let app): app.url
        }
    }

    var body: some View {
        RoomListRow(selected: selected) {
            badge
            Group {
                if let appURL {
                    EntryIconView(source: .file(stamp: FileIconStamp.value(for: appURL)), fileURL: appURL)
                } else {
                    EntryIconView(source: .symbol("macwindow"))
                }
            }
            .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            Text(title)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: metrics.spacing.md)
            Text(trailing)
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityLabel(title)
        .accessibilityValue(place.map { "\(trailing), number \($0) in the room" } ?? trailing)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .strokeBorder(place == nil ? Theme.Colors.cardStroke : .clear, lineWidth: 1)
                .background(Circle().fill(place == nil ? .clear : Theme.Colors.roomCardStroke))
            if let place {
                Text("\(place)")
                    .font(metrics.typography.rowTrailing.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
    }
}

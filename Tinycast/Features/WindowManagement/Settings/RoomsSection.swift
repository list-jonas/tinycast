import SwiftUI

/// The room library, inside the Window Management pane: rooms tile with its gap and its grant.
struct RoomsSection: View {
    @Environment(RoomStore.self) private var store
    @Environment(RoomCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.windowRoomsShowInLauncher) {
                SettingsRowTitle(.windowManagementRooms, "Show rooms in launcher")
            }

            if store.rooms.isEmpty {
                Text("Save a project's windows as a room, then walk into it with one shortcut.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.rooms) { room in
                    RoomSettingsRow(room: room)
                }
            }

            Button {
                coordinator.createRoom()
            } label: {
                SettingsRowTitle(.windowManagementRooms, "New Room")
            }
        } header: {
            SettingsSectionHeader(.windowManagementRooms)
        }
    }
}

private struct RoomSettingsRow: View {
    let room: Room

    @Environment(RoomCoordinator.self) private var coordinator

    private var subtitle: String {
        "\(room.summary) · \(coordinator.layout(of: room).title)"
    }

    var body: some View {
        SettingsRow(title: room.name, subtitle: subtitle) {
            SymbolImage(name: Room.sfSymbol, size: 13)
        } trailing: {
            ShortcutRecorder(action: .windowRoom(id: room.id))
            WindowLibraryRowButton(symbol: "play", help: "Enter this room", label: "Enter \(room.name)") {
                coordinator.enterRoom(id: room.id)
            }
            WindowLibraryRowButton(
                symbol: "macwindow.badge.plus", help: "Choose its windows",
                label: "Choose windows for \(room.name)"
            ) { coordinator.editWindows(of: room) }
            WindowLibraryRowButton(
                symbol: "trash", help: "Delete", label: "Delete \(room.name)", isDestructive: true
            ) { coordinator.deleteRoom(room) }
            WindowLibraryVisibilityToggle(entry: AppEntry(room), name: room.name)
        }
    }
}

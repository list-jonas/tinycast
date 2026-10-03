// Adapted from Rooms (MIT): https://github.com/saragordic/rooms/blob/main/LICENSE
import Foundation

/// A project you walk into: its windows, in order, and how they lay out. See window-rooms.md.
struct Room: Codable, Hashable, WindowLibraryRecord, Sendable {
    static let entryIDPrefix = "window-room:"
    static let sfSymbol = "door.left.hand.open"

    var id = UUID()
    var name: String
    /// The first is the main window: it takes the largest spot and ends frontmost.
    var windows: [RoomWindow] = []
    var layout = RoomLayoutKind.auto
    /// A layout chosen on one display, keyed by its lowercased UUID; `layout` covers the rest.
    var layoutsByDisplay: [String: RoomLayoutKind] = [:]
    var lastEnteredAt: Date?

    func layout(onDisplay uuid: String?) -> RoomLayoutKind {
        uuid.flatMap { layoutsByDisplay[$0.lowercased()] } ?? layout
    }

    /// This room as written elsewhere, keeping what entering `learned` taught this Mac.
    func keepingRuntime(of learned: Room) -> Room {
        var room = self
        room.lastEnteredAt = learned.lastEnteredAt
        // A window's number goes back only to a window of the same app, so an edit can't mismatch.
        for (index, window) in zip(room.windows.indices, learned.windows)
        where window.bundleID == room.windows[index].bundleID {
            room.windows[index].windowID = window.windowID
        }
        return room
    }

    var summary: String { windows.count == 1 ? "1 window" : "\(windows.count) windows" }

    /// Most recently entered first, so the room you just left is one row away.
    static func enteredMoreRecently(_ lhs: Self, _ rhs: Self) -> Bool {
        let left = lhs.lastEnteredAt ?? .distantPast
        let right = rhs.lastEnteredAt ?? .distantPast
        return left != right ? left > right : precedes(lhs, rhs)
    }
}

extension Room {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = (try? container.decodeIfPresent([String: String].self, forKey: .layoutsByDisplay)) ?? [:]
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decode(String.self, forKey: .name),
            windows: try container.decodeIfPresent([RoomWindow].self, forKey: .windows) ?? [],
            // A layout this build does not know resets to Auto rather than losing the room.
            layout: (try? container.decodeIfPresent(RoomLayoutKind.self, forKey: .layout)) ?? .auto,
            layoutsByDisplay: stored.compactMapValues(RoomLayoutKind.init(rawValue:)),
            lastEnteredAt: try container.decodeIfPresent(Date.self, forKey: .lastEnteredAt))
    }
}

enum RoomValidationError: LocalizedError, Equatable {
    case emptyName, duplicateName, noWindows, invalidCharacter

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name for the room."
        case .duplicateName: "A room with this name already exists."
        case .noWindows: "Choose at least one window for the room."
        case .invalidCharacter: "Names cannot contain null characters."
        }
    }
}

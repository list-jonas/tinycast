import Foundation

/// Which screen an entry targets, identified so it survives a reboot and a reconnect.
struct WindowLayoutDisplay: Codable, Hashable, Sendable {
    /// `CGDisplayCreateUUIDFromDisplayID`, stringified by the service layer, never read here.
    var uuid: String
    /// `NSScreen.localizedName` at authoring time, so an absent display can still name itself.
    var name: String
}

extension WindowLayoutDisplay {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            uuid: try container.decode(String.self, forKey: .uuid),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Display")
    }
}

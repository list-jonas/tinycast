import Foundation

/// A named record the user authors and the launcher lists: a layout, a room or a custom size.
protocol WindowLibraryRecord: Identifiable where ID == UUID {
    static var entryIDPrefix: String { get }
    var name: String { get }
}

extension WindowLibraryRecord {
    var entryID: String { Self.entryIDPrefix + id.uuidString.lowercased() }

    static func id(fromEntryID entryID: String) -> UUID? {
        guard entryID.hasPrefix(entryIDPrefix) else { return nil }
        return UUID(uuidString: String(entryID.dropFirst(entryIDPrefix.count)))
    }

    /// The one name order, sorted through by both the store and the `AppIndex` slice.
    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        guard order == .orderedSame else { return order == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

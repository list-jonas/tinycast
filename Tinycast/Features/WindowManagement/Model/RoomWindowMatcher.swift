// Adapted from Rooms (MIT): https://github.com/saragordic/rooms/blob/main/LICENSE
import Foundation

/// Which open window fills which of a room's windows. Each open window is used at most once.
enum RoomWindowMatcher {
    /// Room window index → open window index. `claimed` windows go last: other rooms hold them.
    static func assign(
        _ windows: [RoomWindow], to live: [RoomLiveWindow], claimed: Set<UInt32> = []
    ) -> [Int: Int] {
        // Folded once, not per pair: the similarity pass compares every title with every other.
        let savedTitles = windows.map { folded($0.title) }
        let liveTitles = live.map { folded($0.title) }
        var result: [Int: Int] = [:]
        var used = Set<Int>()
        func pass(_ accepts: (_ saved: Int, _ open: Int) -> Bool) {
            for (index, window) in windows.enumerated() where result[index] == nil {
                guard
                    let match = live.indices.first(where: {
                        !used.contains($0) && live[$0].bundleID == window.bundleID && accepts(index, $0)
                    })
                else { continue }
                result[index] = match
                used.insert(match)
            }
        }
        func isClaimed(_ open: Int) -> Bool { live[open].windowID.map(claimed.contains) ?? false }
        pass { windows[$0].windowID != nil && windows[$0].windowID == live[$1].windowID }
        pass { !windows[$0].title.isEmpty && windows[$0].title == live[$1].title }
        // A title that only looks alike never takes another room's window.
        pass { isSimilarFolded(savedTitles[$0], liveTitles[$1]) && !isClaimed($1) }
        // Titles follow the current tab, so last comes any window of the app, a free one first.
        pass { !isClaimed($1) }
        pass { _, _ in true }
        return result
    }

    /// Titles sharing a meaningful part: "Report — draft 3" and "Report — draft 4".
    static func isSimilar(_ lhs: String, _ rhs: String) -> Bool {
        isSimilarFolded(folded(lhs), folded(rhs))
    }

    private static func isSimilarFolded(_ left: String, _ right: String) -> Bool {
        guard left.count >= 4, right.count >= 4 else { return false }
        if left.contains(right) || right.contains(left) { return true }
        let common = zip(left, right).prefix { $0 == $1 }.count
        return common >= min(12, min(left.count, right.count) * 2 / 3)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

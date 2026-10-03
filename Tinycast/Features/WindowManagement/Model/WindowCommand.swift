import Foundation

struct WindowCommand: Identifiable, Hashable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case leftHalf = "left-half"
        case rightHalf = "right-half"
        case topHalf = "top-half"
        case bottomHalf = "bottom-half"
        case topLeftQuarter = "top-left-quarter"
        case topRightQuarter = "top-right-quarter"
        case bottomLeftQuarter = "bottom-left-quarter"
        case bottomRightQuarter = "bottom-right-quarter"
        case firstThreeFourths = "first-three-fourths"
        case lastThreeFourths = "last-three-fourths"
        case firstThird = "first-third"
        case centerThird = "center-third"
        case lastThird = "last-third"
        case firstTwoThirds = "first-two-thirds"
        case lastTwoThirds = "last-two-thirds"
        case maximize
        case almostMaximize = "almost-maximize"
        case reasonableSize = "reasonable-size"
        case maximizeHeight = "maximize-height"
        case maximizeWidth = "maximize-width"
        case center
        case centerHalf = "center-half"
        case centerTwoThirds = "center-two-thirds"
        case makeLarger = "make-larger"
        case makeSmaller = "make-smaller"
        case restore
        case moveLeft = "move-left"
        case moveRight = "move-right"
        case moveUp = "move-up"
        case moveDown = "move-down"
        case nextDisplay = "next-display"
        case previousDisplay = "previous-display"
        case toggleFullscreen = "toggle-fullscreen"
        case previousSpace = "previous-space"
        case nextSpace = "next-space"
    }

    /// What the mover has to do, so its dispatch stays exhaustive over the catalog.
    enum Kind: String, Sendable {
        case geometry
        /// Geometry sourced from the recorded pre-action frame rather than computed.
        case restore
        case fullscreen
        /// No window at all: a synthetic Dock gesture that moves between Spaces.
        case space
    }

    /// The launcher section a command belongs to, and the order Settings lists them in.
    enum Group: String, CaseIterable, Sendable {
        case halves, quarters, fourths, thirds, sizing, moving, fullscreen, spaces

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    let id: ID
    let name: String
    let sfSymbol: String
    let kind: Kind
    let group: Group
    /// Only the four halves honour `WindowCycle`; the rest ignore the step they are handed.
    let cyclesOnRepeat: Bool
    /// False for the nudges, so the mover never writes `kAXSizeAttribute` for them.
    let resizes: Bool

    var entryID: String { "window-command:" + id.rawValue }
}

enum WindowCommandCatalog {
    static let all: [WindowCommand] = WindowCommand.ID.allCases.map { id in
        let (name, symbol, group) = spec(id)
        return WindowCommand(
            id: id, name: name, sfSymbol: symbol, kind: kind(for: id), group: group,
            cyclesOnRepeat: cyclesOnRepeat.contains(id), resizes: !movesOnly.contains(id))
    }

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    private static let byEntryID = Dictionary(uniqueKeysWithValues: all.map { ($0.entryID, $0) })

    static func command(id: WindowCommand.ID) -> WindowCommand? { byID[id] }

    static func command(forEntryID entryID: String) -> WindowCommand? { byEntryID[entryID] }

    /// `ID.allCases` is in group order, so this partitions.
    static func grouped() -> [(group: WindowCommand.Group, commands: [WindowCommand])] {
        WindowCommand.Group.allCases.compactMap { group in
            let commands = all.filter { $0.group == group }
            return commands.isEmpty ? nil : (group, commands)
        }
    }

    static let cyclesOnRepeat: Set<WindowCommand.ID> = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]

    static let movesOnly: Set<WindowCommand.ID> = [.moveLeft, .moveRight, .moveUp, .moveDown]

    private static func kind(for id: WindowCommand.ID) -> WindowCommand.Kind {
        switch id {
        case .restore: .restore
        case .toggleFullscreen: .fullscreen
        case .previousSpace, .nextSpace: .space
        default: .geometry
        }
    }

    private static func spec(_ id: WindowCommand.ID) -> (String, String, WindowCommand.Group) {
        switch id {
        case .leftHalf: ("Left Half", "rectangle.lefthalf.filled", .halves)
        case .rightHalf: ("Right Half", "rectangle.righthalf.filled", .halves)
        case .topHalf: ("Top Half", "rectangle.tophalf.filled", .halves)
        case .bottomHalf: ("Bottom Half", "rectangle.bottomhalf.filled", .halves)
        case .topLeftQuarter: ("Top Left Quarter", "rectangle.inset.topleading.filled", .quarters)
        case .topRightQuarter: ("Top Right Quarter", "rectangle.inset.toptrailing.filled", .quarters)
        case .bottomLeftQuarter:
            ("Bottom Left Quarter", "rectangle.inset.bottomleading.filled", .quarters)
        case .bottomRightQuarter:
            ("Bottom Right Quarter", "rectangle.inset.bottomtrailing.filled", .quarters)
        case .firstThreeFourths: ("First Three Fourths", "rectangle.lefthalf.inset.filled", .fourths)
        case .lastThreeFourths: ("Last Three Fourths", "rectangle.righthalf.inset.filled", .fourths)
        case .firstThird: ("First Third", "rectangle.leadingthird.inset.filled", .thirds)
        case .centerThird: ("Center Third", "rectangle.center.inset.filled", .thirds)
        case .lastThird: ("Last Third", "rectangle.trailingthird.inset.filled", .thirds)
        case .firstTwoThirds: ("First Two Thirds", "rectangle.leadingthird.inset.filled", .thirds)
        case .lastTwoThirds: ("Last Two Thirds", "rectangle.trailingthird.inset.filled", .thirds)
        case .maximize: ("Maximize", "arrow.up.left.and.arrow.down.right", .sizing)
        case .almostMaximize: ("Almost Maximize", "rectangle.inset.filled", .sizing)
        case .reasonableSize: ("Reasonable Size", "macwindow", .sizing)
        case .maximizeHeight: ("Maximize Height", "arrow.up.and.down", .sizing)
        case .maximizeWidth: ("Maximize Width", "arrow.left.and.right", .sizing)
        case .center: ("Center", "rectangle.center.inset.filled", .sizing)
        case .centerHalf: ("Center Half", "rectangle.split.3x1", .sizing)
        case .centerTwoThirds: ("Center Two Thirds", "rectangle.split.3x1.fill", .sizing)
        case .makeLarger: ("Make Larger", "plus.magnifyingglass", .sizing)
        case .makeSmaller: ("Make Smaller", "minus.magnifyingglass", .sizing)
        case .restore: ("Restore Window", "arrow.uturn.backward", .sizing)
        case .moveLeft: ("Move Left", "arrow.left", .moving)
        case .moveRight: ("Move Right", "arrow.right", .moving)
        case .moveUp: ("Move Up", "arrow.up", .moving)
        case .moveDown: ("Move Down", "arrow.down", .moving)
        case .nextDisplay: ("Move to Next Display", "rectangle.on.rectangle.angled", .moving)
        case .previousDisplay: ("Move to Previous Display", "rectangle.on.rectangle.angled", .moving)
        case .toggleFullscreen:
            ("Toggle Fullscreen", "arrow.up.left.and.arrow.down.right.square", .fullscreen)
        case .previousSpace: ("Switch to Previous Space", "chevron.backward.2", .spaces)
        case .nextSpace: ("Switch to Next Space", "chevron.forward.2", .spaces)
        }
    }
}

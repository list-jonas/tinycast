import CoreGraphics
import Foundation

/// The 3×3 position grid. Raw values are spelled out so renaming a case can't rename a stored one.
enum WindowLayoutAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft = "top-left"
    case top
    case topRight = "top-right"
    case left
    case center
    case right
    case bottomLeft = "bottom-left"
    case bottom
    case bottomRight = "bottom-right"

    /// `place(_:in:)` stays the only anchor arithmetic in the codebase; this is just the spelling.
    var placement: WindowPlacementEngine.Anchor {
        WindowPlacementEngine.Anchor(horizontal: horizontal, vertical: vertical)
    }

    /// The accessibility label for the grid button, and the name a settings row shows.
    var title: String { rawValue.split(separator: "-").map(\.capitalized).joined(separator: " ") }

    private var horizontal: WindowPlacementEngine.Anchor.Axis {
        switch self {
        case .topLeft, .left, .bottomLeft: .min
        case .top, .center, .bottom: .center
        case .topRight, .right, .bottomRight: .max
        }
    }

    /// `.min` is the top, since +Y points down in the AX space every frame here lives in.
    private var vertical: WindowPlacementEngine.Anchor.Axis {
        switch self {
        case .topLeft, .top, .topRight: .min
        case .left, .center, .right: .center
        case .bottomLeft, .bottom, .bottomRight: .max
        }
    }

    /// The one place an axis pair maps back to a case, so the grid and `describe` agree.
    static func named(
        horizontal: WindowPlacementEngine.Anchor.Axis, vertical: WindowPlacementEngine.Anchor.Axis
    ) -> WindowLayoutAnchor {
        allCases.first { $0.horizontal == horizontal && $0.vertical == vertical } ?? .center
    }
}

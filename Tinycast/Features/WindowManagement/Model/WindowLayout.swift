import CoreGraphics
import Foundation

/// One app on one display, sized as a fraction of it. See docs/features/window-layouts.md.
struct WindowLayoutEntry: Codable, Hashable, Identifiable, Sendable {
    /// A stored fraction is only ever a fraction; `WindowLayoutGeometry` owns the 1 pt floor.
    static let fractionRange: ClosedRange<CGFloat> = 0...1
    /// Wider than any display, so a real nudge is never clipped and an absurd stored one is.
    static let offsetLimit: CGFloat = 10_000

    var id = UUID()
    var bundleID: String
    /// A file, folder, URL or deeplink to open the app with; nil is a plain launch.
    var argument: String?
    var display: WindowLayoutDisplay
    var widthFraction: CGFloat = 1
    var heightFraction: CGFloat = 1
    var anchor = WindowLayoutAnchor.center
    /// Points, applied on top of the anchor.
    var offset = CGPoint.zero

    /// The same entry under a fresh identity, for a duplicated layout.
    var copy: WindowLayoutEntry {
        var copy = self
        copy.id = UUID()
        return copy
    }

    /// Clamped rather than rejected: a bad import loses a nudge, never the whole layout.
    static func sanitized(_ entries: [WindowLayoutEntry]) -> [WindowLayoutEntry] {
        entries.compactMap { entry in
            var cleaned = entry
            cleaned.bundleID = entry.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.argument = entry.argument?.cleanedLayoutField
            cleaned.display.uuid = entry.display.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.widthFraction = clampFraction(entry.widthFraction)
            cleaned.heightFraction = clampFraction(entry.heightFraction)
            cleaned.offset = CGPoint(x: clampOffset(entry.offset.x), y: clampOffset(entry.offset.y))
            guard !cleaned.bundleID.isEmpty, !cleaned.display.uuid.isEmpty else { return nil }
            return cleaned
        }
    }

    private static func clampFraction(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, fractionRange.lowerBound), fractionRange.upperBound)
    }

    private static func clampOffset(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, -offsetLimit), offsetLimit)
    }
}

extension WindowLayoutEntry {
    // Hand-written, so an added field keeps stored layouts and older backups readable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            bundleID: try container.decode(String.self, forKey: .bundleID),
            argument: try container.decodeIfPresent(String.self, forKey: .argument),
            display: try container.decode(WindowLayoutDisplay.self, forKey: .display),
            widthFraction: try container.decodeIfPresent(CGFloat.self, forKey: .widthFraction) ?? 1,
            heightFraction: try container.decodeIfPresent(CGFloat.self, forKey: .heightFraction) ?? 1,
            anchor: try container.decodeIfPresent(WindowLayoutAnchor.self, forKey: .anchor) ?? .center,
            offset: try container.decodeIfPresent(CGPoint.self, forKey: .offset) ?? .zero)
    }
}

/// A saved arrangement: these apps, at these sizes, at these positions, on these displays.
struct WindowLayout: Codable, Hashable, WindowLibraryRecord, Sendable {
    static let entryIDPrefix = "window-layout:"
    /// One glyph for every layout, and never the menu bar's own, which reads as the app itself.
    static let sfSymbol = "rectangle.3.group"

    var id = UUID()
    var name: String
    var iconSymbol: String?
    /// Opts the layout into the global `windowGap`, the way the tiling commands use it.
    var usesPreferredGap = true
    var entries: [WindowLayoutEntry] = []
    /// The one entry whose window ends a run frontmost; an ID rather than a flag, so it is one.
    var frontmostEntryID: UUID?

    var symbol: String { iconSymbol ?? Self.sfSymbol }

    var summary: String {
        let displays = Set(entries.map(\.display.uuid)).count
        let windows = entries.count == 1 ? "1 window" : "\(entries.count) windows"
        return displays > 1 ? "\(windows) · \(displays) displays" : windows
    }

    /// Cleans every entry, then drops a frontmost mark whose entry did not survive.
    mutating func sanitizeEntries() {
        entries = WindowLayoutEntry.sanitized(entries)
        if !entries.contains(where: { $0.id == frontmostEntryID }) { frontmostEntryID = nil }
    }
}

extension WindowLayout {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decode(String.self, forKey: .name),
            iconSymbol: try container.decodeIfPresent(String.self, forKey: .iconSymbol),
            usesPreferredGap: try container.decodeIfPresent(Bool.self, forKey: .usesPreferredGap) ?? true,
            entries: try container.decodeIfPresent([WindowLayoutEntry].self, forKey: .entries) ?? [],
            frontmostEntryID: try container.decodeIfPresent(UUID.self, forKey: .frontmostEntryID))
    }
}

extension String {
    /// Trimmed, and nil when that leaves nothing: an empty optional field means "unset", not "".
    fileprivate var cleanedLayoutField: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("\0") ? nil : trimmed
    }
}

enum WindowLayoutValidationError: LocalizedError, Equatable {
    case emptyName, duplicateName, noEntries, invalidCharacter

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name for the layout."
        case .duplicateName: "A window layout with this name already exists."
        case .noEntries: "Add at least one app to the layout."
        case .invalidCharacter: "Names cannot contain null characters."
        }
    }
}

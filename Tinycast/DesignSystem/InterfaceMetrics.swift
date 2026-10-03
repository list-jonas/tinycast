import SwiftUI

/// `Theme`'s palette geometry at the user's Interface Size; `.standard` is `Theme` verbatim.
struct InterfaceMetrics: Equatable, Sendable {
    static let standard = InterfaceMetrics(scale: 1)

    let scale: CGFloat

    var spacing: Spacing { Spacing(scale: scale) }
    var radius: Radius { Radius(scale: scale) }
    var size: Size { Size(scale: scale) }
    var typography: Typography { Typography(scale: scale) }

    /// For a tuned length a surface owns itself, where `Theme` states no token for it.
    func scaled(_ value: CGFloat) -> CGFloat { scaledPoints(value, scale) }

    /// Every `Theme.Spacing` token, scaled; a key path, so no token can be mirrored wrong.
    @dynamicMemberLookup
    struct Spacing: Equatable, Sendable {
        let scale: CGFloat

        subscript(dynamicMember token: KeyPath<Theme.Spacing.Type, CGFloat>) -> CGFloat {
            scaledPoints(Theme.Spacing.self[keyPath: token], scale)
        }
    }

    @dynamicMemberLookup
    struct Radius: Equatable, Sendable {
        let scale: CGFloat

        subscript(dynamicMember token: KeyPath<Theme.Radius.Type, CGFloat>) -> CGFloat {
            scaledPoints(Theme.Radius.self[keyPath: token], scale)
        }
    }

    /// Derived sizes are stated, since a sum of scaled parts rounds unlike a scaled sum.
    @dynamicMemberLookup
    struct Size: Equatable, Sendable {
        let scale: CGFloat

        subscript(dynamicMember token: KeyPath<Theme.Size.Type, CGFloat>) -> CGFloat {
            scaledPoints(Theme.Size.self[keyPath: token], scale)
        }

        /// The compact bar must stay exactly the header in symmetric slack.
        var compactHeight: CGFloat { self.headerHeight + self.headerPadding * 2 }
        /// The row cap still counts whole rows at every size.
        var menuRowHeight: CGFloat { self.menuIcon + Spacing(scale: scale).md * 2 }
        var menuRowsMaxHeight: CGFloat {
            (Theme.Size.menuVisibleRows * (menuRowHeight + self.menuRowSpacing)).rounded()
        }
        var dialogButtonHeight: CGFloat {
            self.menuButton - scaledPoints(Theme.Size.menuButton - Theme.Size.dialogButtonHeight, scale)
        }
    }

    /// `NSFont` is the only public source of a text style's size and face.
    struct Typography: Sendable {
        let scale: CGFloat

        var searchFieldSize: CGFloat { scaledPoints(Theme.Typography.searchFieldSize, scale) }
        var searchField: Font {
            scale == 1
                ? Theme.Typography.searchField
                : .system(size: searchFieldSize, weight: .regular)
        }
        /// Isolated because `Theme`'s twin is, not because resolving a font needs main.
        @MainActor var searchFieldNSFont: NSFont {
            scale == 1
                ? Theme.Typography.searchFieldNSFont
                : NSFont.systemFont(ofSize: searchFieldSize, weight: .regular)
        }
        var headerIcon: Font {
            scale == 1
                ? Theme.Typography.headerIcon
                : .system(size: scaledPoints(18, scale), weight: .medium)
        }

        var rowTitle: Font { font(Theme.Typography.rowTitle, .body) }
        var rowTrailing: Font { font(Theme.Typography.rowTrailing, .callout) }
        var sectionHeader: Font { font(Theme.Typography.sectionHeader, .subheadline, .medium) }
        var panelTitle: Font { font(Theme.Typography.panelTitle, .headline) }
        var calcResult: Font { font(Theme.Typography.calcResult, .title1) }
        var keyCap: Font { font(Theme.Typography.keyCap, .caption1) }
        var compactKeyCap: Font { font(Theme.Typography.compactKeyCap, .caption2) }
        var heroKeyCap: Font { font(Theme.Typography.heroKeyCap, .body) }
        var markdownHeading1: Font { font(Theme.Typography.markdownHeading1, .title2, .semibold) }
        var markdownHeading2: Font { font(Theme.Typography.markdownHeading2, .title3, .semibold) }
        var markdownHeading3: Font { font(Theme.Typography.markdownHeading3, .headline) }
        var code: Font {
            scale == 1
                ? Theme.Typography.code
                : .system(size: nsFont(.callout).pointSize, design: .monospaced)
        }
        var inlineCode: Font { font(Theme.Typography.inlineCode, .body).monospaced() }
        var bar: Font { font(Theme.Typography.bar, .callout, .medium) }
        var chip: Font { font(Theme.Typography.chip, .callout) }
        @MainActor var chipNSFont: NSFont { scale == 1 ? Theme.Typography.chipNSFont : nsFont(.callout) }
        var disclosure: Font { font(Theme.Typography.disclosure, .caption1, .semibold) }
        var menuRow: Font { font(Theme.Typography.menuRow, .body) }
        var menuShortcut: Font { font(Theme.Typography.menuShortcut, .callout) }
        var menuIcon: Font { font(Theme.Typography.menuIcon, .body) }

        /// The AppKit twin of a text style, for text an `NSTextView` draws beside SwiftUI's own.
        func textNSFont(
            _ style: NSFont.TextStyle, weight: NSFont.Weight? = nil, monospaced: Bool = false
        ) -> NSFont {
            let base = nsFont(style)
            if monospaced { return .monospacedSystemFont(ofSize: base.pointSize, weight: weight ?? .regular) }
            guard let weight else { return base }
            return .systemFont(ofSize: base.pointSize, weight: weight)
        }

        /// Composed like `Theme`'s own: the style carries the face, an explicit weight overrides it.
        private func font(
            _ base: Font, _ style: NSFont.TextStyle, _ weight: Font.Weight? = nil
        )
            -> Font
        {
            guard scale != 1 else { return base }
            let scaled = Font(nsFont(style))
            return weight.map(scaled.weight) ?? scaled
        }

        /// Its own descriptor, so `.headline` stays Bold and `.caption2` Medium rather than lightening.
        private func nsFont(_ style: NSFont.TextStyle) -> NSFont {
            let base = NSFont.preferredFont(forTextStyle: style)
            guard scale != 1 else { return base }
            return NSFont(descriptor: base.fontDescriptor, size: scaledPoints(base.pointSize, scale)) ?? base
        }
    }
}

/// Whole points: a fractional row pitch lands keycap edges and the dissolve mask off-pixel.
private func scaledPoints(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
    scale == 1 ? value : (value * scale).rounded()
}

extension EnvironmentValues {
    /// `.standard` by default, so a shared `DesignSystem` view outside the palette never scales.
    @Entry var metrics = InterfaceMetrics.standard
}

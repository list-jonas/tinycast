import Foundation
import SwiftUI

/// The one source of row order, so the palette's flat `selection` maps 1:1 onto visible rows.
struct ExtensionScreen: Equatable {
    struct SelectionChange: Equatable {
        let handler: String
        let itemID: String?
    }

    enum Kind: Equatable {
        case list
        case grid(ExtensionGridLayout)
        case detail
        case form
        /// A root component the palette does not render, or nothing rendered yet.
        case unsupported(String)
    }

    /// `id` is the scroll target: an `.id()` inside a row exists only once it is realized.
    struct Item: Equatable, Identifiable {
        let node: RenderNode
        let index: Int

        var id: String { "item:\(node.id)" }
    }

    enum Row: Equatable, Identifiable {
        case header(title: String, subtitle: String?, id: String)
        case item(Item)

        var id: String {
            switch self {
            case .header(_, _, let id): return "header:" + id
            case .item(let item): return item.id
            }
        }
    }

    private(set) var kind = Kind.unsupported("")
    private(set) var root: RenderNode?
    private(set) var rows: [Row] = []
    /// Selectable rows in visible order — what `selection` indexes.
    private(set) var items: [Item] = []
    /// Fields of a Form, in order.
    private(set) var fields: [RenderNode] = []
    private(set) var isLoading = false
    private(set) var navigationTitle: String?
    private(set) var searchPlaceholder: String?
    /// True when the palette filters rows itself; false when the extension owns the search text.
    private(set) var filtersLocally = false
    private(set) var searchTextHandler: String?
    private(set) var selectionHandler: String?
    private(set) var selectedItemID: String?
    private(set) var searchBarAccessory: RenderNode?
    /// The `List`-level `isShowingDetail`; when set, rows get a detail pane beside them.
    private(set) var showsDetail = false
    /// Actions attached to the screen itself (`Detail`/`Form`/`List` level).
    private(set) var screenActions: RenderNode?
    /// An `EmptyView` to show when there are no rows.
    private(set) var emptyView: RenderNode?

    /// Selectable rows per section: what grid navigation needs to keep a column across a heading.
    var sectionCounts: [Int] {
        var counts: [Int] = []
        for row in rows {
            switch row {
            case .header:
                counts.append(0)
            case .item:
                if counts.isEmpty { counts.append(0) }
                counts[counts.count - 1] += 1
            }
        }
        // An empty section is drawn but holds nothing to land on, so it isn't a row of the grid.
        return counts.filter { $0 > 0 }
    }

    static let empty = ExtensionScreen()

    private init() {}

    /// Filters rows by `query` only when the extension hasn't taken the search text over.
    init(tree: RenderTree, query: String) {
        guard let root = tree.activeRoot else {
            self = .empty
            return
        }
        self.root = root
        isLoading = root.bool("isLoading") ?? false
        navigationTitle = root.string("navigationTitle")
        searchPlaceholder = root.string("searchBarPlaceholder")
        searchTextHandler = root.handler("onSearchTextChange")
        selectionHandler = root.handler("onSelectionChange")
        selectedItemID = root.string("selectedItemId")
        searchBarAccessory = root.node("searchBarAccessory")
        showsDetail = root.bool("isShowingDetail") ?? false
        screenActions = root.node("actions")
        filtersLocally =
            root.bool("filtering") ?? (root.object("filtering") != nil || searchTextHandler == nil)

        switch root.type {
        case "List": kind = .list
        case "Grid": kind = .grid(ExtensionGridLayout(root))
        case "Detail": kind = .detail
        case "Form": kind = .form
        default: kind = .unsupported(root.type)
        }

        switch kind {
        case .list, .grid:
            let itemType = root.type == "Grid" ? "Grid.Item" : "List.Item"
            let sectionType = root.type == "Grid" ? "Grid.Section" : "List.Section"
            let emptyType = root.type == "Grid" ? "Grid.EmptyView" : "List.EmptyView"
            emptyView = root.children.first { $0.type == emptyType }
            let needle = FuzzyMatch.Query(filtersLocally ? query.trimmingCharacters(in: .whitespaces) : "")
            var rows: [Row] = []
            var items: [Item] = []
            // Numbering as rows are built keeps `selection` and the drawn order in step.
            func append(_ node: RenderNode) {
                let item = Item(node: node, index: items.count)
                items.append(item)
                rows.append(.item(item))
            }
            for child in root.children {
                if child.type == sectionType {
                    let matching = child.children
                        .filter { $0.type == itemType }
                        .filter { ExtensionScreen.matches($0, needle) }
                    guard !matching.isEmpty else { continue }
                    rows.append(
                        .header(
                            title: child.string("title") ?? "",
                            subtitle: child.string("subtitle"), id: String(child.id)))
                    matching.forEach(append)
                } else if child.type == itemType, ExtensionScreen.matches(child, needle) {
                    append(child)
                }
            }
            self.rows = rows
            self.items = items

        case .form:
            fields = root.children.filter { $0.type.hasPrefix("Form.") }
            // A form's focusable fields are its selectable rows, so ↑/↓ and ⇥ walk one order.
            var fieldItems: [Item] = []
            for field in fields where ExtensionFormField(type: field.type).isFocusable {
                fieldItems.append(Item(node: field, index: fieldItems.count))
            }
            items = fieldItems

        case .detail, .unsupported:
            break
        }
    }

    var selectedItemIndex: Int? {
        guard let selectedItemID else { return nil }
        return items.firstIndex { $0.node.string("id") == selectedItemID }
    }

    /// Resolves the List/Grid callback after local filtering changes the visible row order.
    func selectionChange(at index: Int) -> SelectionChange? {
        guard let selectionHandler else { return nil }
        let itemID = items.indices.contains(index) ? items[index].node.string("id") : nil
        return SelectionChange(handler: selectionHandler, itemID: itemID)
    }

    /// Title, subtitle and keywords, ranked by the launcher's matcher.
    static func matches(_ item: RenderNode, _ needle: FuzzyMatch.Query) -> Bool {
        guard !needle.isEmpty else { return true }
        var haystack = [item.string("title") ?? ""]
        if let subtitle = item.string("subtitle") { haystack.append(subtitle) }
        haystack.append(contentsOf: item.array("keywords").compactMap(\.stringValue))
        return haystack.contains { FuzzyMatch.score(needle, candidate: $0) != nil }
    }

    /// The `ActionPanel` that applies to the current selection: the item's own, else the screen's.
    func actionPanel(forItemAt index: Int) -> RenderNode? {
        if items.indices.contains(index), let panel = items[index].node.node("actions") {
            return panel
        }
        return screenActions
    }

    /// Where a drawn field sits in the focus order, or nil for one that is never landed on.
    func focusItem(for field: RenderNode) -> Item? {
        items.first { $0.node.id == field.id }
    }

    /// The field a form opens on: the one that asked for it, else the first one there is.
    var autoFocusedField: Int {
        items.first { $0.node.bool("autoFocus") == true }?.index ?? 0
    }

    /// Submenus flatten into their section: the palette's menu is flat.
    static func actions(in panel: RenderNode?) -> [ExtensionAction] {
        guard let panel else { return [] }
        var result: [ExtensionAction] = []
        // By node, not title: untitled sections are the common case and must still separate.
        var previousSection: RenderNode.ID?
        // submenuTitle: the outermost submenu an action sits under, so ⏎ can open it instead.
        func walk(_ node: RenderNode, section: RenderNode.ID?, submenuTitle: String?) {
            for child in node.children {
                switch child.type {
                case "Action":
                    let startsSection = !result.isEmpty && section != previousSection
                    result.append(
                        ExtensionAction(
                            node: child, startsSection: startsSection,
                            enclosingSubmenuTitle: submenuTitle))
                    previousSection = section
                case "ActionPanel.Section":
                    walk(child, section: child.id, submenuTitle: submenuTitle)
                case "ActionPanel.Submenu":
                    walk(child, section: section, submenuTitle: submenuTitle ?? child.string("title"))
                default:
                    break
                }
            }
        }
        walk(panel, section: nil, submenuTitle: nil)
        return result
    }
}

/// One activatable action from an `ActionPanel`.
struct ExtensionAction: Equatable, Identifiable {
    let node: RenderNode
    /// True for the first action after a section boundary, so the menu draws a separator above it.
    let startsSection: Bool
    /// The outermost enclosing submenu's title, if any, so ⏎ can open it instead of firing.
    let enclosingSubmenuTitle: String?

    var id: Int { node.id }
    var title: String { node.string("title") ?? "Action" }
    var handler: String? { node.handler("onAction") }
    var isDestructive: Bool { node.string("style") == "destructive" }
    var iconValue: RenderValue? { node.props["icon"] }

    /// A cross-platform shortcut nests the real one under `macOS`.
    private var shortcut: (key: String, modifiers: [String])? {
        guard let raw = node.object("shortcut") else { return nil }
        let resolved = raw["macOS"]?.objectValue ?? raw
        guard let key = resolved["key"]?.stringValue else { return nil }
        return (key, (resolved["modifiers"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    /// `{modifiers: ["cmd","shift"], key: "c"}` rendered as the palette's keycap glyphs.
    var shortcutCaps: [String]? {
        guard let shortcut else { return nil }
        return shortcut.modifiers.compactMap { Self.modifiers[$0]?.cap } + [Self.keyCap(shortcut.key)]
    }

    /// Modifiers must match exactly, so ⌘⇧C never fires a plain ⌘C action.
    func matches(key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        guard let shortcut else { return false }
        let expected = shortcut.modifiers.reduce(into: EventModifiers()) { flags, name in
            if let flag = Self.modifiers[name]?.flag { flags.insert(flag) }
        }
        let pressed = modifiers.intersection([.command, .control, .option, .shift])
        return pressed == expected && Self.keyEquivalent(shortcut.key) == key
    }

    private static let modifiers: [String: (flag: EventModifiers, cap: String)] = [
        "cmd": (.command, "⌘"), "ctrl": (.control, "⌃"), "opt": (.option, "⌥"), "alt": (.option, "⌥"),
        "shift": (.shift, "⇧")
    ]

    /// Raycast's `KeyEquivalent` names → SwiftUI's, and the keycap each draws.
    private static let namedKeys: [String: (key: KeyEquivalent, cap: String)] = [
        "return": (.return, "↵"), "enter": (.return, "↵"), "delete": (.delete, "⌫"),
        "backspace": (.delete, "⌫"), "deleteForward": (.deleteForward, "⌦"), "tab": (.tab, "⇥"),
        "arrowUp": (.upArrow, "↑"), "arrowDown": (.downArrow, "↓"), "arrowLeft": (.leftArrow, "←"),
        "arrowRight": (.rightArrow, "→"), "escape": (.escape, "⎋"), "space": (.space, "␣"),
        "pageUp": (.pageUp, "⇞"), "pageDown": (.pageDown, "⇟"), "home": (.home, "↖"), "end": (.end, "↘")
    ]

    private static func keyEquivalent(_ key: String) -> KeyEquivalent {
        namedKeys[key]?.key ?? KeyEquivalent(Character(key.lowercased().first.map(String.init) ?? " "))
    }

    private static func keyCap(_ key: String) -> String {
        namedKeys[key]?.cap ?? key.uppercased()
    }
}

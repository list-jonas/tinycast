import Foundation

/// One choice in a picker's list: a `Form.Dropdown`/`Form.TagPicker` or the search-bar dropdown.
struct ExtensionPickerItem: Identifiable, Equatable {
    let value: String
    let title: String
    var detail: String?
    var iconValue: RenderValue?
    /// The section this choice was declared under, drawn above the first of them.
    var section: String?

    var id: String { value }

    /// A picker's choices: direct children, or grouped in sections that carry the heading.
    static func items(in node: RenderNode) -> [ExtensionPickerItem] {
        var items: [ExtensionPickerItem] = []
        func walk(_ node: RenderNode, section: String?) {
            for child in node.children {
                if child.type.hasSuffix(".Item") {
                    let value = child.string("value") ?? ""
                    items.append(
                        ExtensionPickerItem(
                            value: value, title: child.string("title") ?? value,
                            iconValue: child.props["icon"], section: section))
                } else if child.type.hasSuffix(".Section") {
                    walk(child, section: child.string("title"))
                }
            }
        }
        walk(node, section: nil)
        return items
    }
}

extension [ExtensionPickerItem] {
    /// The section of the row before `index`, so only the first of a run draws its heading.
    func section(before index: Int) -> String? { index > 0 ? self[index - 1].section : nil }

    /// Headings a list of these draws, which its height and its flip decision both count.
    var headingCount: Int {
        indices.count(where: { self[$0].section != nil && self[$0].section != section(before: $0) })
    }
}

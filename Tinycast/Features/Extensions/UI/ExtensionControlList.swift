import SwiftUI

/// The open list a dropdown, tag picker and date field share, typed into the control itself.
struct ExtensionControlList {
    var open = false
    var query = ""
    /// When the query last changed, which is where the caret's blink restarts from.
    var typedAt = Date()
    var highlighted = 0
    var hovered = false
    /// Reported by the panel once it has placed itself, for the chevron that points its way.
    var flipped = false

    mutating func show(highlighting row: Int) {
        guard !open else { return }
        query = ""
        highlighted = row
        open = true
    }

    mutating func close() {
        guard open else { return }
        open = false
        query = ""
    }

    mutating func move(_ delta: Int, rows: Int) {
        guard rows > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), rows - 1)
    }
}

/// Focus, keys, the floating list and its teardown, wired the same way for every list control.
struct ExtensionControlListBehavior<Panel: View, Revision: Equatable>: ViewModifier {
    @Binding var list: ExtensionControlList
    let index: Int?
    @FocusState.Binding var focus: Int?
    let field: ExtensionFormField
    let height: CGFloat
    let revision: Revision
    let rows: Int
    let initialRow: () -> Int
    let commit: () -> Void
    let step: (Int) -> KeyPress.Result
    let onSubmit: () -> Void
    let panel: () -> Panel
    /// Told while the list is up, so the palette leaves every navigation key to it.
    @Environment(PaletteState.self) private var palette

    func body(content: Content) -> some View {
        content
            .onHover { list.hovered = $0 }
            .onTapGesture {
                focus = index
                if list.open { list.close() } else { list.show(highlighting: initialRow()) }
            }
            .focusable()
            .focused($focus, equals: index)
            // The chrome draws the focused edge, so AppKit's blue ring would be a second one.
            .focusEffectDisabled()
            .extensionListPanel(
                open: list.open, height: height, revision: revision, flipped: $list.flipped,
                list: panel)
            .onKeyPress(phases: [.down, .repeat], action: handle)
            .modifier(
                ExtensionFormKeys(
                    field: field,
                    onActivate: {
                        if list.open { commit() } else { list.show(highlighting: initialRow()) }
                    },
                    onSubmit: {
                        list.close()
                        onSubmit()
                    }))
            .onChange(of: list.open) { palette.noteControlListOpen(list.open) }
            .onChange(of: list.query) { list.typedAt = Date() }
            .onScrollVisibilityChange { if !$0 { list.close() } }
            .onChange(of: palette.controlListDismissToken) { list.close() }
            .onDisappear { if list.open { palette.noteControlListOpen(false) } }
            // Focus leaving the field takes its list with it.
            .onChange(of: focus) { _, focus in if focus != index { list.close() } }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard !palette.menuOpen, !ExtensionFormKey.enterKeys.contains(press.key) else { return .ignored }
        switch ExtensionListKey(press: press, listOpen: list.open) {
        case .openList: list.show(highlighting: initialRow())
        case .moveUp: list.move(-1, rows: rows)
        case .moveDown: list.move(1, rows: rows)
        case .commit: commit()
        case .dismiss: list.close()
        case .append(let characters):
            list.query += characters
            list.highlighted = 0
        case .deleteBackward:
            guard !list.query.isEmpty else { return .handled }
            list.query.removeLast()
            list.highlighted = 0
        case .stepValue(let delta): return step(delta)
        case .ignored: return .ignored
        }
        return .handled
    }
}

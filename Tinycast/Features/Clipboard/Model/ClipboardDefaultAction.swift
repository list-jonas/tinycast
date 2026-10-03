/// What ↵ does on a clipboard entry; Paste takes the chord the chosen action leaves free.
enum ClipboardDefaultAction: String, CaseIterable, Identifiable, Sendable {
    case paste
    case copy
    case pastePlainText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return "Paste"
        case .copy: return "Copy to Clipboard"
        case .pastePlainText: return "Paste as Plain Text"
        }
    }

    /// What `chord` runs on `item` with this as the default; nil when it has no text to paste.
    func action(for chord: ClipboardChord, on item: ClipboardItem) -> Self? {
        let hasPlainText = item.plainText != nil
        // An image has no text, so a plain-text default pastes it as it is.
        let resolved: Self = self == .pastePlainText && !hasPlainText ? .paste : self
        let action: Self =
            switch chord {
            case .return: resolved
            case resolved.ownChord: .paste
            case .command: .copy
            case .controlCommand: .pastePlainText
            }
        return action == .pastePlainText && !hasPlainText ? nil : action
    }

    /// The chord an action answers while Paste is the default.
    private var ownChord: ClipboardChord {
        switch self {
        case .paste: .return
        case .copy: .command
        case .pastePlainText: .controlCommand
        }
    }
}

/// The ↵ chords a default reorders; ⌥↵ always pastes, so it is not one of them.
enum ClipboardChord: CaseIterable, Sendable {
    case `return`
    case command
    case controlCommand

    var label: String {
        switch self {
        case .return: "↵"
        case .command: "⌘↵"
        case .controlCommand: "⌃⌘↵"
        }
    }
}

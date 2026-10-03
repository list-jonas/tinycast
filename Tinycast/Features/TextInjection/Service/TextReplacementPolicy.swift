import Foundation

/// Its own shape, not a caller's result type, so the injector stays owned by no one feature.
struct InjectedText: Equatable, Sendable {
    let text: String
    /// Leaves the caret this many characters back from the end; nil leaves it after the text.
    let cursorOffsetFromEnd: Int?

    init(_ text: String, cursorOffsetFromEnd: Int? = nil) {
        self.text = text
        self.cursorOffsetFromEnd = cursorOffsetFromEnd
    }

    /// UTF-16 distance from the start of the inserted text to where the caret should land.
    var caretPrefixLength: Int {
        let offset = min(max(cursorOffsetFromEnd ?? 0, 0), text.count)
        return text[..<text.index(text.endIndex, offsetBy: -offset)].utf16.count
    }
}

enum AccessibilityReplacement: Equatable {
    case delivered
    case unavailable
    case rejected

    /// `.rejected` means the document is not the one we measured, so events would edit the wrong text.
    var fallsBackToEvents: Bool { self == .unavailable }
}

/// The two judgements a replacement makes, kept pure so the harness can drive both tiers.
enum TextReplacementPolicy {
    enum KeywordState: Equatable {
        case matched(NSRange)
        case pending
        case rejected
    }

    /// Too little text yet is a renderer still catching up; enough text but wrong is a real mismatch.
    static func keywordState(
        value: String, selectedRange: NSRange, keyword: String
    ) -> KeywordState {
        guard selectedRange.length == 0,
            let selectedStringRange = Range(selectedRange, in: value)
        else { return .rejected }
        let beforeCursor = value[..<selectedStringRange.lowerBound]
        guard beforeCursor.count >= keyword.count else { return .pending }
        let start = beforeCursor.index(beforeCursor.endIndex, offsetBy: -keyword.count)
        guard beforeCursor[start...].lowercased() == keyword.lowercased() else { return .rejected }
        return .matched(NSRange(start..<beforeCursor.endIndex, in: value))
    }

    /// Chromium answers `.success` and applies nothing, so the value has to read back as we wrote it.
    static func confirmsReplacement(
        originalValue: String,
        replacementRange: NSRange,
        insertedText: String,
        observedValue: String?
    ) -> Bool {
        guard let observedValue,
            let stringRange = Range(replacementRange, in: originalValue)
        else { return false }
        var expected = originalValue
        expected.replaceSubrange(stringRange, with: insertedText)
        return observedValue == expected
    }
}

enum PasteConfirmationPolicy {
    static func acceptsUnconfirmedDelivery(
        attempt: Int, hadPreviousState: Bool, readStateAfterPaste: Bool
    ) -> Bool {
        attempt >= 15 && (!hadPreviousState || !readStateAfterPaste)
    }
}

/// Blink keeps one key event's text in a fixed four-unit array, so Chromium drops everything past it.
enum UnicodeTypingChunk {
    static let maxUTF16Units = 4

    /// Split on scalar boundaries: a lone surrogate half is not text, and a scalar always fits four.
    static func split(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        current.reserveCapacity(maxUTF16Units)
        for scalar in text.unicodeScalars {
            if current.count + UTF16.width(scalar) > maxUTF16Units {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            UTF16.encode(scalar) { current.append($0) }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

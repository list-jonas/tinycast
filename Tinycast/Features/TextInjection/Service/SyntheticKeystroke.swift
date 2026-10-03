import AppKit
import Carbon.HIToolbox

/// Tagged key events, so our own tap and the clipboard poller recognise what we typed.
enum SyntheticKeystroke {
    typealias Pair = [CGEvent]

    static func unicode(_ text: String) -> [Pair]? {
        var groups: [Pair] = []
        for chunk in UnicodeTypingChunk.split(text) {
            guard let pair = key(unicode: chunk) else { return nil }
            groups.append(pair)
        }
        return groups
    }

    static func deletions(_ count: Int) -> [Pair]? {
        var groups: [Pair] = []
        groups.reserveCapacity(count)
        for _ in 0..<count {
            guard let pair = key(code: CGKeyCode(kVK_Delete)) else { return nil }
            groups.append(pair)
        }
        return groups
    }

    /// Flags are always cleared: the source inherits held modifiers, and a hotkey's are still down.
    static func key(code: CGKeyCode = 0, unicode: [UniChar]? = nil) -> Pair? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return nil }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: Paster.tinycastEventTag)
            if var characters = unicode {
                event.keyboardSetUnicodeString(
                    stringLength: characters.count, unicodeString: &characters)
            }
        }
        return [down, up]
    }

    static func post(_ events: Pair, to app: NSRunningApplication?) {
        for event in events {
            if let pid = app?.processIdentifier {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }
    }
}

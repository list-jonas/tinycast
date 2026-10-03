import AppKit

extension NSScreen {
    /// The display in use; `NSScreen.main` is the key window's, which we rarely have.
    static var underCursor: NSScreen? {
        let mouse = NSEvent.mouseLocation
        // NSMouseInRect, not `contains`: the topmost row otherwise reads as the display above.
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }

    /// The menu-bar display: the one at the global origin, which `NSScreen.main` is not.
    static var primary: NSScreen? {
        screens.first { $0.frame.origin == .zero } ?? screens.first
    }
}

extension NSWindow {
    /// Lifted off true centre on the cursor's display: an exactly centred panel reads low.
    func centerOnCursorScreen() {
        guard let visible = NSScreen.underCursor?.visibleFrame else { return }
        setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2 + visible.height * 0.08))
    }
}

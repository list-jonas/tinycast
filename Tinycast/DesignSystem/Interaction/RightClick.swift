import SwiftUI

/// An overlay claiming only right-mouse events, so the popover anchors to a fixed point.
private struct RightClickCatcher: NSViewRepresentable {
    let action: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(action: action) }
    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.action = action }

    final class CatcherView: NSView {
        var action: (CGPoint) -> Void
        init(action: @escaping (CGPoint) -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        // Flipped so the reported point matches SwiftUI's top-left local coordinate space.
        override var isFlipped: Bool { true }

        override func rightMouseDown(with event: NSEvent) {
            action(convert(event.locationInWindow, from: nil))
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }
    }
}

extension View {
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        overlay(RightClickCatcher { _ in action() })
    }

    /// Reports where the click landed, so one catcher serves every cell in a grid.
    func onRightClick(perform action: @escaping (CGPoint) -> Void) -> some View {
        overlay(RightClickCatcher(action: action))
    }
}

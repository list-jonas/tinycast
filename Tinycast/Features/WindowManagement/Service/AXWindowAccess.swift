// Portions adapted from Rooms (MIT): https://github.com/saragordic/rooms/blob/main/LICENSE
import AppKit
// `@preconcurrency` downgrades AX diagnostics: `kAX…` are mutable C globals, but constant.
@preconcurrency import ApplicationServices

/// Every `AXUIElement` call in the feature, so no two callers disagree on what a window is.
@MainActor
enum AXWindowAccess {
    /// A hung target must not stall main for the AX default. Per element, never inherited.
    static let messagingTimeout: Float = 1
    /// Slack when checking whether the app honoured the size we asked for.
    static let clampTolerance: CGFloat = 2

    static let fullScreenAttribute = "AXFullScreen" as CFString
    static let fullScreenButtonAttribute = "AXFullScreenButton" as CFString

    // MARK: - Finding windows

    static func application(for pid: pid_t, timeout: Float = messagingTimeout) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        return application
    }

    /// The window a command acts on: focused, else main, else the first eligible one.
    static func targetWindow(in application: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = element(application, attribute), isEligible(window) { return window }
        }
        return windows(in: application).first(where: isEligible)
    }

    /// Every window the app reports, unfiltered and in its own order.
    static func windows(in application: AXUIElement) -> [AXUIElement] {
        copy(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    /// A real, restorable window: not a sheet, popover or minimized one, and it reports geometry.
    private static func isEligible(_ window: AXUIElement) -> Bool {
        string(window, kAXRoleAttribute) == (kAXWindowRole as String)
            && bool(window, kAXMinimizedAttribute) != true && frame(of: window) != nil
    }

    static func isFullScreen(_ window: AXUIElement) -> Bool {
        bool(window, fullScreenAttribute as String) ?? false
    }

    // MARK: - Bringing one forward

    static func unminimize(_ window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
    }

    /// Raises the window inside its app, then brings the app itself forward.
    static func focus(_ window: AXUIElement, in application: AXUIElement, of app: NSRunningApplication) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        // Belt and braces with `activate()`: an agent-policy app's request can be ignored.
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate()
    }

    /// Orders a window forward across apps: a raise alone reorders it only inside its own app.
    static func raise(_ window: AXUIElement, in application: AXUIElement) {
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// The fallback for an app that refuses `NSRunningApplication.hide()` or `unhide()`.
    static func setHidden(_ hidden: Bool, application: AXUIElement) {
        AXUIElementSetAttributeValue(
            application, kAXHiddenAttribute as CFString, hidden ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Web-based apps list no windows until this is on, and draw focus rings while it stays on.
    static func setManualAccessibility(_ enabled: Bool, application: AXUIElement) {
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }

    // MARK: - Window identity

    /// The window server's number, which outlives any `AXUIElement`. See window-rooms.md.
    static func windowID(of window: AXUIElement) -> UInt32? {
        guard let copyWindowID else { return nil }
        var id: CGWindowID = 0
        return copyWindowID(window, &id) == .success && id != 0 ? id : nil
    }

    private typealias CopyWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Private, so resolved at run time: a macOS without it degrades to titles, never a crash.
    private static let copyWindowID: CopyWindowID? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: CopyWindowID.self)
    }()

    // MARK: - Writing a frame

    /// Places a window a run found, if it can be moved at all; false leaves it untouched.
    static func place(
        _ frame: CGRect, anchor: WindowPlacementEngine.Anchor, canvas: CGRect?, on window: AXUIElement
    ) -> Bool {
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        guard isSettable(kAXPositionAttribute, on: window), let current = self.frame(of: window) else {
            return false
        }
        return write(
            frame, anchor: anchor, to: window, current: current,
            canResize: isSettable(kAXSizeAttribute, on: window), canvas: canvas) != nil
    }

    /// The one write sequence, so a stubborn app lands the same way from any caller.
    /// See docs/features/window-management.md#applying-a-placement.
    static func write(
        _ target: CGRect, anchor: WindowPlacementEngine.Anchor, to window: AXUIElement,
        current: CGRect, canResize: Bool, canvas: CGRect?
    ) -> CGRect? {
        func reseat(_ size: CGSize) -> Bool {
            var slot = anchor.place(size, in: target)
            if let canvas { slot = WindowPlacementEngine.clamped(slot, into: canvas) }
            return setPosition(WindowPlacementEngine.rounded(slot).origin, on: window)
        }
        guard canResize else {
            guard reseat(current.size) else { return nil }
            return frame(of: window) ?? current
        }

        _ = setSize(target.size, on: window)
        guard setPosition(target.origin, on: window) else {
            _ = setSize(current.size, on: window)  // Roll the shrink back; nothing visibly moved.
            return nil
        }
        _ = setSize(target.size, on: window)
        guard var actual = frame(of: window) else { return target }

        // The second resize can shift the origin: some apps anchor on a different corner.
        if abs(actual.minX - target.minX) > clampTolerance || abs(actual.minY - target.minY) > clampTolerance {
            _ = setPosition(target.origin, on: window)
            actual = frame(of: window) ?? actual
        }
        // An app-imposed minimum: re-place once per the anchor. No loop, which would jitter.
        if actual.width > target.width + clampTolerance || actual.height > target.height + clampTolerance {
            _ = reseat(actual.size)
            actual = frame(of: window) ?? actual
        }
        return actual
    }

    /// Cleared for the writes, never while VoiceOver runs. See docs/features/window-management.md.
    static func suppressEnhancedUserInterface(on application: AXUIElement) -> () -> Void {
        let attribute = "AXEnhancedUserInterface"
        guard !NSWorkspace.shared.isVoiceOverEnabled, bool(application, attribute) == true else { return {} }
        AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanFalse)
        return { AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue) }
    }

    // MARK: - Primitives

    static func frame(of window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = axValue(window, kAXPositionAttribute, .cgPoint),
            AXValueGetValue(position, .cgPoint, &origin),
            let extent = axValue(window, kAXSizeAttribute, .cgSize), AXValueGetValue(extent, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func setPosition(_ origin: CGPoint, on window: AXUIElement) -> Bool {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    static func setSize(_ size: CGSize, on window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // Type checked by CFGetTypeID above; `as?` on a CF type is a compile error.
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Type checked by CFGetTypeID above; `as?` on a CF type is a compile error.
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copy(element, attribute) as? Bool
    }

    static func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}

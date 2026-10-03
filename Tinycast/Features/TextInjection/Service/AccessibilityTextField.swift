import AppKit
@preconcurrency import ApplicationServices

/// The focused text element's value and selection, as the replacement tier reads and writes them.
struct AccessibilityTextField {
    struct State: Equatable {
        let value: String
        let selectedRange: NSRange
    }

    let element: AXUIElement

    /// Web content and Monaco expose selection only as markers; their `AXValue` trails or is empty.
    static func focused(in app: NSRunningApplication) -> AccessibilityTextField? {
        guard let element = AccessibilityText.focusedElement(in: app) else { return nil }
        var marker: CFTypeRef?
        let usesMarkers =
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextMarkerRangeAttribute as CFString, &marker) == .success
            && marker.map { CFGetTypeID($0) == AXTextMarkerRangeGetTypeID() } == true
        return usesMarkers ? nil : AccessibilityTextField(element: element)
    }

    var value: String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    var selectedRange: NSRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range)
        else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    var state: State? {
        guard let value, let selectedRange else { return nil }
        return State(value: value, selectedRange: selectedRange)
    }

    var acceptsReplacement: Bool {
        isSettable(kAXSelectedTextRangeAttribute) && isSettable(kAXSelectedTextAttribute)
    }

    @discardableResult
    func select(_ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func replaceSelection(with text: String) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }
}

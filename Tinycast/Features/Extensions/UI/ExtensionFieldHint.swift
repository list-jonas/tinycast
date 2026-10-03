import SwiftUI

/// Carries a field's error and `info` to the control; drawn text alone is never spoken.
struct ExtensionFieldHint: ViewModifier {
    let info: String?
    var error: String?

    func body(content: Content) -> some View {
        let spoken = Self.spoken(error, info)
        if spoken.isEmpty {
            content
        } else {
            content.accessibilityHint(Text(spoken))
        }
    }

    /// The non-empty parts, read in order as sentences.
    static func spoken(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

extension View {
    /// The field's own explanation, spoken as well as shown.
    func extensionFieldHint(_ info: String?, error: String? = nil) -> some View {
        modifier(ExtensionFieldHint(info: info, error: error))
    }
}

import SwiftUI

/// A symbol falling back to a bundled asset of the same name, since not all are system.
struct SymbolImage: View {
    let name: String
    let size: CGFloat
    var monochrome = false

    var body: some View {
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            Image(name)
                .renderingMode(monochrome ? .template : nil)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: .regular))
                .symbolRenderingMode(monochrome ? .monochrome : .hierarchical)
        }
    }
}

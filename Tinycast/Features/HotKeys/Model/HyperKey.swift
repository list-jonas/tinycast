import Carbon.HIToolbox
import CoreGraphics

/// The physical key remapped to the Hyper chord. See docs/features/hotkeys.md#the-hyper-key.
enum HyperKeyPhysicalKey: String, CaseIterable, Identifiable, Sendable {
    case none
    case capsLock
    case rightControl, rightShift, rightOption, rightCommand

    var id: String { rawValue }

    /// The single glyph Hyper shortcuts collapse to.
    static let hyperGlyph = "✦"

    var title: String {
        switch self {
        case .none: "None"
        case .capsLock: "Caps Lock (⇪)"
        case .rightControl: "Right Control (⌃)"
        case .rightShift: "Right Shift (⇧)"
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        }
    }

    /// Virtual key code of the physical key, `nil` only for `.none`.
    var keyCode: Int? {
        switch self {
        case .none: nil
        case .capsLock: kVK_CapsLock
        case .rightControl: kVK_RightControl
        case .rightShift: kVK_RightShift
        case .rightOption: kVK_RightOption
        case .rightCommand: kVK_RightCommand
        }
    }

    /// The keycode the tap watches; Caps Lock is HID-remapped to F18 while it serves as Hyper.
    var tapKeyCode: Int? {
        self == .capsLock ? kVK_F18 : keyCode
    }

    /// Whether presses arrive as keyDown/keyUp (Caps Lock via F18) or as `flagsChanged`.
    var tapUsesKeyEvents: Bool { self == .capsLock }

    /// Keys that do something on their own when not remapped — these get the Quick Press row.
    var hasOriginalFunction: Bool { self == .capsLock }

    /// The generic flag this key contributes, so the tap can strip it when outside the set.
    var ownFlag: CGEventFlags? {
        switch self {
        case .none: nil
        case .capsLock: .maskAlphaShift
        case .rightControl: .maskControl
        case .rightShift: .maskShift
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        }
    }

    /// Quick Press label for triggering the key's original function.
    var quickPressOriginalTitle: String? {
        self == .capsLock ? "Trigger Caps Lock (⇪)" : nil
    }
}

/// What a quick lone press of the Hyper key does (only offered for keys with an original function).
enum HyperKeyQuickPress: String, CaseIterable, Sendable {
    case none
    case originalKey
    case escape
}

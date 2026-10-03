import Foundation

/// Raw values must match `LaunchType` in `enums.generated.js`, which is what JS compares against.
enum ExtensionLaunchType: String, Sendable {
    case userInitiated
    case background
}

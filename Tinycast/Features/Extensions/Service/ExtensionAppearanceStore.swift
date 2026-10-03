import Foundation

/// Keyed by manifest name like preferences, so a reinstall keeps the choice.
@MainActor
@Observable
final class ExtensionAppearanceStore {
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let key = "extensionAppearances"

    private(set) var overrides: [String: ExtensionAppearance]

    init() {
        overrides = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: ExtensionAppearance].self, from: $0) } ?? [:]
    }

    func appearance(for extensionName: String) -> ExtensionAppearance? {
        overrides[extensionName]
    }

    /// `nil` restores the extension's own icon.
    func set(_ appearance: ExtensionAppearance?, for extensionName: String) {
        overrides[extensionName] = appearance
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: key)
    }
}

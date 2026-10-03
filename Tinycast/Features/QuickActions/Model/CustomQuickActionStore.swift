import Foundation

@MainActor
@Observable
final class CustomQuickActionStore {
    private(set) var actions: [CustomQuickAction] = []
    /// False when the file wouldn't read; every mutation then refuses rather than pretends.
    private(set) var isAvailable = true
    @ObservationIgnored var onChange: (([CustomQuickAction]) -> Void)?

    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? AppPaths.applicationSupport()
        fileURL = base.appendingPathComponent("quick-actions.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        // A file that exists but won't read is authored data: report, never write over it.
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([CustomQuickAction].self, from: data)
        else {
            isAvailable = false
            return
        }
        actions = Self.sanitized(decoded)
    }

    func action(id: UUID) -> CustomQuickAction? {
        actions.first { $0.id == id }
    }

    func action(entryID: String) -> CustomQuickAction? {
        CustomQuickAction.id(fromEntryID: entryID).flatMap(action)
    }

    @discardableResult
    func add(_ draft: CustomQuickAction) throws(CustomQuickActionError) -> CustomQuickAction {
        let value = try Self.validated(draft)
        try commit(actions + [value])
        return value
    }

    func update(_ draft: CustomQuickAction) throws(CustomQuickActionError) {
        guard let index = actions.firstIndex(where: { $0.id == draft.id }) else { return }
        var updated = actions
        updated[index] = try Self.validated(draft)
        try commit(updated)
    }

    @discardableResult
    func remove(id: UUID) throws(CustomQuickActionError) -> CustomQuickAction? {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = actions
        let removed = updated.remove(at: index)
        try commit(updated)
        return removed
    }

    func setPreviewsResult(
        _ previews: Bool, id: UUID
    ) throws(CustomQuickActionError) {
        guard var value = action(id: id), value.previewsResult != previews else { return }
        value.previewsResult = previews
        try update(value)
    }

    private static func validated(
        _ draft: CustomQuickAction
    ) throws(CustomQuickActionError) -> CustomQuickAction {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.iconSymbol =
            draft.iconSymbol?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        value.instructions = draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw .emptyName }
        guard !value.name.contains("\0") else { throw .invalidCharacter }
        guard !value.instructions.isEmpty else { throw .emptyInstructions }
        return value
    }

    /// Persisted before the list moves, so a save the reader was told landed is on disk.
    private func commit(_ updated: [CustomQuickAction]) throws(CustomQuickActionError) {
        guard isAvailable else { throw .storageUnavailable }
        let ordered = updated.sorted(by: CustomQuickAction.precedes)
        guard ordered != actions else { return }
        try persist(ordered)
        actions = ordered
        onChange?(ordered)
    }

    private func persist(_ values: [CustomQuickAction]) throws(CustomQuickActionError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(values),
            (try? data.write(to: fileURL, options: .atomic)) != nil
        else { throw .storageUnavailable }
    }

    private static func sanitized(_ values: [CustomQuickAction]) -> [CustomQuickAction] {
        var ids = Set<UUID>()
        return values.compactMap { try? validated($0) }
            .filter { ids.insert($0.id).inserted }
            .sorted(by: CustomQuickAction.precedes)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

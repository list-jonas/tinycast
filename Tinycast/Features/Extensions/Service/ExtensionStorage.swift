import Foundation

/// One JSON file per extension; a `Cache` runs to megabytes, so the read is preloaded off-main.
@MainActor
final class ExtensionStorage {
    private struct Store: Codable, Sendable {
        var localStorage: [String: StoredValue] = [:]
        var caches: [String: [String: String]] = [:]
        var preferences: [String: StoredValue] = [:]
    }

    /// `LocalStorage` accepts strings, numbers and booleans and must return them with their type.
    enum StoredValue: Codable, Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)

        var jsonValue: Any {
            switch self {
            case .string(let value): return value
            case .number(let value): return value
            case .bool(let value): return value
            }
        }

        init?(renderValue: RenderValue) {
            switch renderValue {
            case .string(let value): self = .string(value)
            case .number(let value): self = .number(value)
            case .bool(let value): self = .bool(value)
            default: return nil
            }
        }

        init(preference: ExtensionPreferenceValue) {
            switch preference {
            case .string(let value): self = .string(value)
            case .number(let value): self = .number(value)
            case .bool(let value): self = .bool(value)
            }
        }

        var preferenceValue: ExtensionPreferenceValue {
            switch self {
            case .string(let value): return .string(value)
            case .number(let value): return .number(value)
            case .bool(let value): return .bool(value)
            }
        }
    }

    private let directory: URL
    private var stores: [String: Store] = [:]
    /// Writes are coalesced, so a busy `Cache` doesn't hit the disk per key.
    private var dirty: Set<String> = []
    private var flushTask: Task<Void, Never>?
    /// The write a previous `flush()` handed off. Awaiting `dirty` alone would miss it entirely.
    private var writeTask: Task<Void, Never>?
    /// Bumped by `removeAll`, so a preload decoded before an uninstall cannot resurrect it.
    private var generation = 0

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - LocalStorage

    func localStorageValue(extension name: String, key: String) -> StoredValue? {
        store(for: name).localStorage[key]
    }

    func allLocalStorage(extension name: String) -> [String: StoredValue] {
        store(for: name).localStorage
    }

    func setLocalStorage(extension name: String, key: String, value: StoredValue) {
        mutate(name) { $0.localStorage[key] = value }
    }

    func removeLocalStorage(extension name: String, key: String) {
        mutate(name) { $0.localStorage.removeValue(forKey: key) }
    }

    func clearLocalStorage(extension name: String) {
        mutate(name) { $0.localStorage.removeAll() }
    }

    // MARK: - Cache

    func caches(extension name: String) -> [String: [String: String]] {
        store(for: name).caches
    }

    /// `nil` removes the key; a `nil` key clears the namespace.
    func setCache(extension name: String, namespace: String, key: String?, value: String?) {
        mutate(name) { store in
            guard let key else {
                store.caches[namespace] = [:]
                return
            }
            var bucket = store.caches[namespace] ?? [:]
            if let value { bucket[key] = value } else { bucket.removeValue(forKey: key) }
            store.caches[namespace] = bucket
        }
    }

    func clearCache(extension name: String, namespace: String) {
        mutate(name) { $0.caches[namespace] = [:] }
    }

    // MARK: - Preferences

    func preference(extension name: String, key: String) -> ExtensionPreferenceValue? {
        store(for: name).preferences[key]?.preferenceValue
    }

    func setPreference(extension name: String, key: String, value: ExtensionPreferenceValue?) {
        mutate(name) { store in
            if let value {
                store.preferences[key] = StoredValue(preference: value)
            } else {
                store.preferences.removeValue(forKey: key)
            }
        }
    }

    /// Manifest defaults overlaid with the user's — what `getPreferenceValues()` sees.
    func resolvedPreferences(
        extension name: String, schemas: [ExtensionPreferenceSchema]
    ) -> [String: ExtensionPreferenceValue] {
        var resolved: [String: ExtensionPreferenceValue] = [:]
        for schema in schemas {
            resolved[schema.name] = preference(extension: name, key: schema.name) ?? schema.effectiveDefault
        }
        return resolved
    }

    /// A command with an unset required preference must not run, exactly as in Raycast.
    func missingRequiredPreferences(
        extension name: String, schemas: [ExtensionPreferenceSchema]
    ) -> [ExtensionPreferenceSchema] {
        schemas.filter { schema in
            guard schema.required else { return false }
            let value = preference(extension: name, key: schema.name) ?? schema.effectiveDefault
            if case .string(let text) = value { return text.isEmpty }
            return false
        }
    }

    func removeAll(extension name: String) {
        // Invalidates any decode already in flight, which would otherwise write the store back.
        generation &+= 1
        stores.removeValue(forKey: name)
        dirty.remove(name)
        try? FileManager.default.removeItem(at: fileURL(for: name))
    }

    // MARK: - Persistence

    private func store(for name: String) -> Store {
        if let existing = stores[name] { return existing }
        let loaded =
            (try? Data(contentsOf: fileURL(for: name)))
            .flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
        stores[name] = loaded
        return loaded
    }

    /// Off-main, so the launch never pays `store(for:)`'s decode; anything in memory already wins.
    func preload(extension name: String) async {
        guard stores[name] == nil else { return }
        let url = fileURL(for: name)
        // `removeAll` also leaves nil, so without this an uninstall mid-decode restores the store.
        let entered = generation
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
        }.value
        guard let loaded, stores[name] == nil, generation == entered else { return }
        stores[name] = loaded
    }

    private func mutate(_ name: String, _ body: (inout Store) -> Void) {
        var current = store(for: name)
        body(&current)
        stores[name] = current
        dirty.insert(name)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.flush()
        }
    }

    /// Awaiting it makes the write durable; an empty `dirty` still leaves one in flight.
    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        let pending = dirty
        dirty.removeAll()
        // Snapshot on the actor, encode off it: ~9 ms of serializing is a dropped frame otherwise.
        let writes = pending.compactMap { name in stores[name].map { ($0, fileURL(for: name)) } }
        // Chained, so two flushes cannot race the same file and land the older snapshot last.
        let previous = writeTask
        let task = Task.detached(priority: .utility) {
            await previous?.value
            for (store, url) in writes {
                guard let data = try? JSONEncoder().encode(store) else { continue }
                try? data.write(to: url, options: .atomic)
            }
        }
        writeTask = task
        await task.value
        // Only the newest write clears the slot; an overlapping flush leaves its own in place.
        if writeTask == task { writeTask = nil }
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent("\(ExtensionCatalog.safeName(name)).json")
    }
}

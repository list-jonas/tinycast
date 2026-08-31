import Foundation

@main
@MainActor
struct ExtensionStorageTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        } else {
            print("PASS  \(message)")
        }
    }

    static func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-storage-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An awaited flush is the durability contract every teardown relies on.
    static func flushedWritesSurviveAReload() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = ExtensionStorage(directory: directory)
        writer.setCache(extension: "demo", namespace: "default", key: "k", value: "v1")
        writer.setLocalStorage(extension: "demo", key: "ls", value: .string("stored"))
        writer.setPreference(extension: "demo", key: "token", value: .string("secret"))
        await writer.flush()

        let reloaded = ExtensionStorage(directory: directory)
        expect(reloaded.caches(extension: "demo")["default"]?["k"] == "v1", "a flushed cache reloads")
        expect(
            reloaded.localStorageValue(extension: "demo", key: "ls") == .string("stored"),
            "flushed local storage reloads")
        expect(
            reloaded.preference(extension: "demo", key: "token") == .string("secret"),
            "a flushed preference reloads")
    }

    /// A store big enough that its decode cannot finish before the racing write is scheduled.
    /// A small one returns from `preload` too early to interleave, which is no test at all.
    static func seedLargeStore(_ directory: URL, extension name: String, marker: String) async {
        let seed = ExtensionStorage(directory: directory)
        // Few keys, big values: the decode has to be slow, and the harness compiles at -Onone where
        // a per-key loop dominates. 2 000 x 4 KB is ~8 MB of JSON either way.
        for index in 0..<2_000 {
            seed.setCache(
                extension: name, namespace: "default", key: "k\(index)",
                value: String(repeating: "x", count: 4_096))
        }
        seed.setCache(extension: name, namespace: "default", key: "marker", value: marker)
        await seed.flush()
    }

    /// The launch path preloads off-main; a write landing mid-decode must not be overwritten.
    static func aWriteDuringPreloadIsNotClobbered() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await seedLargeStore(directory, extension: "demo", marker: "old")

        let storage = ExtensionStorage(directory: directory)
        async let preloading: Void = storage.preload(extension: "demo")
        // Suspends first, so the write lands while the decode is genuinely in flight — without this
        // the write runs to completion before `preload` ever reads the file, and nothing races.
        await Task.yield()
        storage.setCache(extension: "demo", namespace: "default", key: "marker", value: "new")
        await preloading

        expect(
            storage.caches(extension: "demo")["default"]?["marker"] == "new",
            "a write during preload wins over the decoded copy")
    }

    /// `stop()` treats an awaited flush as durable, so it must also cover a write already running.
    /// The store is large and the wake lands just past the 250 ms debounce, so the handed-off write
    /// is still running when `flush()` is called — the window the durability contract has to cover.
    static func flushAwaitsAWriteAlreadyInFlight() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = ExtensionStorage(directory: directory)
        for index in 0..<2_000 {
            storage.setCache(
                extension: "demo", namespace: "default", key: "k\(index)",
                value: String(repeating: "x", count: 4_096))
        }
        try? await Task.sleep(for: .milliseconds(252))
        await storage.flush()

        let size =
            (try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("demo.json").path)[.size] as? Int) ?? 0
        expect((size ?? 0) > 0, "an awaited flush covers a write handed off before it")
    }

    /// Deleting the file after the preload is what proves it: the data can only still be readable
    /// if the decode actually landed in memory, rather than `store(for:)` reloading it inline.
    static func preloadActuallyLoadsTheStore() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await seedLargeStore(directory, extension: "demo", marker: "seeded")

        let storage = ExtensionStorage(directory: directory)
        await storage.preload(extension: "demo")
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("demo.json"))

        expect(
            storage.caches(extension: "demo")["default"]?["marker"] == "seeded",
            "preload leaves the store in memory rather than deferring the read")
    }

    /// Two flushes overlapping must not let an older snapshot land last.
    static func overlappingFlushesKeepTheNewestSnapshot() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await seedLargeStore(directory, extension: "demo", marker: "OLD")

        let storage = ExtensionStorage(directory: directory)
        storage.setCache(extension: "demo", namespace: "default", key: "marker", value: "OLD")
        async let first: Void = storage.flush()
        storage.setCache(extension: "demo", namespace: "default", key: "marker", value: "NEW")
        async let second: Void = storage.flush()
        _ = await (first, second)

        let reloaded = ExtensionStorage(directory: directory)
        expect(
            reloaded.caches(extension: "demo")["default"]?["marker"] == "NEW",
            "the newest snapshot is the one left on disk")
    }

    /// An uninstall landing mid-decode must win: otherwise the store — credentials and all — returns.
    static func uninstallDuringPreloadIsNotResurrected() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await seedLargeStore(directory, extension: "demo", marker: "old")
        let seed = ExtensionStorage(directory: directory)
        seed.setLocalStorage(extension: "demo", key: "token", value: .string("secret"))
        await seed.flush()

        let storage = ExtensionStorage(directory: directory)
        async let preloading: Void = storage.preload(extension: "demo")
        await Task.yield()
        storage.removeAll(extension: "demo")
        await preloading
        // Another extension's write drives a flush, which is what would rewrite the revived store.
        storage.setCache(extension: "other", namespace: "default", key: "k", value: "v")
        await storage.flush()

        expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("demo.json").path),
            "an uninstall during preload leaves the file deleted")
        expect(
            storage.localStorageValue(extension: "demo", key: "token") == nil,
            "an uninstalled extension's credentials do not come back")
    }

    /// Preloading is an optimisation, so it has to be a no-op wherever there is nothing to read.
    static func preloadIsHarmlessWithoutAStore() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = ExtensionStorage(directory: directory)
        await storage.preload(extension: "never-written")
        expect(storage.caches(extension: "never-written").isEmpty, "a missing store preloads empty")

        storage.setCache(extension: "never-written", namespace: "default", key: "k", value: "v")
        await storage.preload(extension: "never-written")
        expect(
            storage.caches(extension: "never-written")["default"]?["k"] == "v",
            "preloading an in-memory store leaves it alone")
    }

    /// `removeAll` is the uninstall path: nothing keyed to the extension may come back.
    static func removeAllDropsTheFile() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = ExtensionStorage(directory: directory)
        storage.setCache(extension: "demo", namespace: "default", key: "k", value: "v")
        await storage.flush()
        storage.removeAll(extension: "demo")

        let reloaded = ExtensionStorage(directory: directory)
        expect(reloaded.caches(extension: "demo").isEmpty, "uninstalling drops the stored file")
    }

    static func main() async {
        await flushedWritesSurviveAReload()
        await aWriteDuringPreloadIsNotClobbered()
        await flushAwaitsAWriteAlreadyInFlight()
        await preloadActuallyLoadsTheStore()
        await overlappingFlushesKeepTheNewestSnapshot()
        await uninstallDuringPreloadIsNotResurrected()
        await preloadIsHarmlessWithoutAStore()
        await removeAllDropsTheFile()

        print(failures == 0 ? "Extension storage tests passed" : "\(failures) tests failed")
        exit(failures == 0 ? 0 : 1)
    }
}

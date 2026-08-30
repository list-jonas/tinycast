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

    /// The launch path preloads off-main; a write landing mid-decode must not be overwritten.
    static func aWriteDuringPreloadIsNotClobbered() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = ExtensionStorage(directory: directory)
        seed.setCache(extension: "demo", namespace: "default", key: "k", value: "old")
        await seed.flush()

        let storage = ExtensionStorage(directory: directory)
        async let preloading: Void = storage.preload(extension: "demo")
        storage.setCache(extension: "demo", namespace: "default", key: "k", value: "new")
        await preloading

        expect(
            storage.caches(extension: "demo")["default"]?["k"] == "new",
            "a write during preload wins over the decoded copy")
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
        await preloadIsHarmlessWithoutAStore()
        await removeAllDropsTheFile()

        print(failures == 0 ? "Extension storage tests passed" : "\(failures) tests failed")
        exit(failures == 0 ? 0 : 1)
    }
}

import Darwin
import Foundation

@MainActor
@Observable
final class SnippetsStore {
    enum State: Sendable, Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var snippets: [StoredSnippet] = []
    private(set) var state: State = .idle
    private(set) var issues: [SnippetRepository.Issue] = []
    private(set) var operationError: String?

    private(set) var snippetsDirectory: URL
    var onSnapshot: ((SnippetRepository.Snapshot) -> Void)?

    private var repository: SnippetRepository
    @ObservationIgnored private var directoryWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var watcherRetryTask: Task<Void, Never>?
    private var generation = 0
    private var watcherGeneration = 0
    private var isStarted = false

    init(repository: SnippetRepository = SnippetRepository()) {
        self.repository = repository
        snippetsDirectory = repository.snippetsDirectory
    }

    isolated deinit {
        reloadTask?.cancel()
        watcherRetryTask?.cancel()
        directoryWatcher?.cancel()
        for source in fileWatchers.values { source.cancel() }
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await reload(showLoadingState: true)
    }

    func stop() {
        isStarted = false
        generation &+= 1
        reloadTask?.cancel()
        reloadTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        stopWatchers()
    }

    /// Moves to another folder; a running store stops, swaps, and loads the new one.
    func relocate(to repository: SnippetRepository) async {
        guard repository.snippetsDirectory != snippetsDirectory else { return }
        let wasStarted = isStarted
        stop()
        self.repository = repository
        snippetsDirectory = repository.snippetsDirectory
        // Emptied first, so a folder that fails to load leaves no old snippet expanding.
        if !snippets.isEmpty || !issues.isEmpty {
            snippets = []
            issues = []
            onSnapshot?(SnippetRepository.Snapshot(records: [], issues: []))
        }
        guard wasStarted else { return }
        await start()
    }

    func retry() {
        guard isStarted else { return }
        scheduleReload(after: .zero, showLoadingState: true)
    }

    @discardableResult
    func create(_ snippet: Snippet) async throws -> StoredSnippet {
        publishLocal(replacing: try await performMutation { try $0.create(snippet) })
    }

    @discardableResult
    func importSnippets(_ imported: [Snippet]) async throws -> [StoredSnippet] {
        guard !imported.isEmpty else { return [] }
        let created = try await performMutation { try $0.create(imported) }
        guard isStarted else { return created }
        let createdIDs = Set(created.map(\.id))
        publishLocal(records: snippets.filter { !createdIDs.contains($0.id) } + created)
        scheduleReload(after: .zero)
        return created
    }

    @discardableResult
    func save(_ record: StoredSnippet) async throws -> StoredSnippet {
        publishLocal(
            replacing: try await performMutation {
                try $0.save(record.snippet, fileURL: record.fileURL, expectedRevision: record.sourceRevision)
            })
    }

    func delete(id: StoredSnippet.ID) async throws {
        guard let record = record(id: id) else {
            throw SnippetRepository.RepositoryError.fileNotFound(URL(fileURLWithPath: id))
        }
        try await performMutation {
            try $0.delete(fileURL: record.fileURL, expectedRevision: record.sourceRevision)
        }
        guard isStarted else { return }
        publishLocal(records: snippets.filter { $0.id != id })
        scheduleReload(after: .zero)
    }

    func record(id: StoredSnippet.ID) -> StoredSnippet? {
        snippets.first(where: { $0.id == id })
    }

    private func performMutation<Value: Sendable>(
        _ operation: @escaping @Sendable (SnippetRepository) throws -> Value
    ) async throws -> Value {
        reloadTask?.cancel()
        reloadTask = nil
        generation &+= 1
        switch await detached(operation) {
        case .success(let value):
            operationError = nil
            return value
        case .failure(let error):
            operationError = error.localizedDescription
            throw error
        }
    }

    /// Every repository call is blocking IO, so it runs off-main and reports one typed failure.
    private func detached<Value: Sendable>(
        _ operation: @escaping @Sendable (SnippetRepository) throws -> Value
    ) async -> Result<Value, SnippetRepository.RepositoryError> {
        let repository = repository
        return await Task.detached(priority: .utility) {
            do {
                return .success(try operation(repository))
            } catch let error as SnippetRepository.RepositoryError {
                return .failure(error)
            } catch {
                return .failure(
                    .io(fileURL: repository.snippetsDirectory, message: error.localizedDescription))
            }
        }.value
    }

    private func reload(showLoadingState: Bool) async {
        guard isStarted else { return }
        generation &+= 1
        let loadGeneration = generation
        if showLoadingState { state = .loading }
        let result = await detached { try $0.load() }
        guard isStarted, loadGeneration == generation else { return }
        switch result {
        case .success(let snapshot):
            apply(snapshot)
        case .failure(let error):
            state = .failed(error.localizedDescription)
            scheduleWatcherRetry()
        }
    }

    private func publishLocal(replacing record: StoredSnippet) -> StoredSnippet {
        guard isStarted else { return record }
        publishLocal(records: snippets.filter { $0.id != record.id } + [record])
        scheduleReload(after: .zero)
        return record
    }

    private func publishLocal(records: [StoredSnippet]) {
        let sorted = records.sorted(by: StoredSnippet.libraryOrder)
        apply(SnippetRepository.Snapshot(records: sorted, issues: issues))
    }

    private func apply(_ snapshot: SnippetRepository.Snapshot) {
        guard isStarted else { return }
        if state != .ready || snippets != snapshot.records || issues != snapshot.issues {
            snippets = snapshot.records
            issues = snapshot.issues
            state = .ready
            onSnapshot?(snapshot)
        }
        if syncWatchers(with: snapshot) {
            scheduleReload(after: .milliseconds(150))
        }
    }

    private func scheduleReload(after delay: Duration, showLoadingState: Bool = false) {
        guard isStarted else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if delay != .zero, (try? await Task.sleep(for: delay)) == nil { return }
            guard let self, self.isStarted, !Task.isCancelled else { return }
            await self.reload(showLoadingState: showLoadingState)
        }
    }

    private func syncWatchers(with snapshot: SnippetRepository.Snapshot) -> Bool {
        guard isStarted else { return false }
        watcherRetryTask?.cancel()
        watcherRetryTask = nil

        var changed = false
        if directoryWatcher == nil {
            let installed = watcherGeneration &+ 1
            directoryWatcher = makeWatcher(path: snippetsDirectory.path) { [weak self] in
                self?.handleDirectoryEvent(generation: installed)
            }
            if directoryWatcher != nil {
                watcherGeneration = installed
                changed = true
            }
        }

        let desiredPaths = Set(
            snapshot.records.map { $0.fileURL.standardizedFileURL.path }
                + snapshot.issues.map { $0.fileURL.standardizedFileURL.path })
        for path in Array(fileWatchers.keys) where !desiredPaths.contains(path) {
            fileWatchers.removeValue(forKey: path)?.cancel()
            changed = true
        }
        for path in desiredPaths where fileWatchers[path] == nil {
            let installed = watcherGeneration
            fileWatchers[path] = makeWatcher(path: path) { [weak self] in
                self?.handleFileEvent(path: path, generation: installed)
            }
            changed = changed || fileWatchers[path] != nil
        }

        // Retry while anything is unwatched; a failed file watcher blinds us like a missing one.
        if directoryWatcher == nil || desiredPaths.contains(where: { fileWatchers[$0] == nil }) {
            scheduleWatcherRetry()
        }
        return changed
    }

    private func makeWatcher(
        path: String, onEvent: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onEvent() } }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    private func handleDirectoryEvent(generation installedGeneration: Int) {
        guard isStarted, installedGeneration == watcherGeneration,
            let events = directoryWatcher?.data
        else { return }

        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            stopWatchers()
        }
        noteFilesystemChange()
    }

    private func handleFileEvent(path: String, generation installedGeneration: Int) {
        guard isStarted, installedGeneration == watcherGeneration,
            let source = fileWatchers[path]
        else { return }

        if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
            fileWatchers.removeValue(forKey: path)?.cancel()
        }
        noteFilesystemChange()
    }

    private func noteFilesystemChange() {
        generation &+= 1
        scheduleReload(after: .milliseconds(150))
    }

    private func stopWatchers() {
        watcherGeneration &+= 1
        directoryWatcher?.cancel()
        directoryWatcher = nil
        for source in fileWatchers.values { source.cancel() }
        fileWatchers.removeAll()
    }

    private func scheduleWatcherRetry() {
        guard isStarted, watcherRetryTask == nil else { return }
        watcherRetryTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(1))) != nil, let self, self.isStarted,
                !Task.isCancelled
            else { return }
            self.watcherRetryTask = nil
            await self.reload(showLoadingState: false)
        }
    }
}

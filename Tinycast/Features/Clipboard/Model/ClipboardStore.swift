import Foundation
import SQLite3

private typealias SQL = ClipboardDatabase

/// SQLite-backed clipboard history. See docs/features/clipboard.md#store.
@MainActor
@Observable
final class ClipboardStore {
    /// Newest-first with pins in place, every pin resident. docs/features/clipboard.md
    private(set) var items: [ClipboardItem] = [] {
        didSet {
            if !textSearchMatches.isEmpty {
                let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                textSearchMatches = textSearchMatches.map { current[$0.id] ?? $0 }
            }
            invalidateSearch(preservingMatches: true)
            onItemsChanged?()
        }
    }
    @ObservationIgnored var onItemsChanged: (() -> Void)?
    @ObservationIgnored var onSearchResultsChanged: ((String, [ClipboardItem], [ClipboardItem]) -> Void)?
    /// Rotated whenever the history is replaced, so a helper's late answer lands on nothing.
    @ObservationIgnored private(set) var extractionGeneration = UUID()
    /// The only thing a view observes for search freshness; `items` cannot speak for OCR.
    private var searchRevision = 0
    @ObservationIgnored private(set) var textSearchEnabled = false
    @ObservationIgnored private var textSearchActive = true
    @ObservationIgnored private var textSearchTask: Task<Void, Never>?
    @ObservationIgnored private var textSearchNeedsRefresh = false
    @ObservationIgnored private var textSearchQuery: String?
    @ObservationIgnored private var textSearchFilter: ClipboardFilter?
    @ObservationIgnored private var textSearchRequest: UUID?
    @ObservationIgnored private var textSearchMatches: [ClipboardItem] = []

    var maxAge: TimeInterval = ClipboardRetention.threeMonths.maxAge

    /// One-entry memo so repeated renders reuse the FTS result; cleared when `items` changes.
    @ObservationIgnored private var searchCache:
        (query: String, filter: ClipboardFilter, result: [ClipboardItem])?
    /// Same memo for the empty query, so the pinned split runs once per mutation.
    @ObservationIgnored private var orderedCache: [ClipboardItem]?

    /// Internal, not private: a backup names both to stream the table and adopt its blobs.
    let imagesDir: URL
    let dbURL: URL
    @ObservationIgnored private var db: OpaquePointer?
    @ObservationIgnored private var statements: [Statement: OpaquePointer] = [:]

    private enum Statement: CaseIterable {
        case insert, load, windowFloor, search, deleteByID, pin, staleImages, deleteStale

        var sql: String {
            switch self {
            case .insert: SQL.insertSQL
            // Two indexed branches, deliberately not one OR. See docs/features/clipboard.md#store.
            case .load:
                """
                SELECT \(SQL.columns) FROM (
                  SELECT rowid AS rid, * FROM items WHERE rowid >= ?1
                  UNION ALL
                  SELECT rowid AS rid, * FROM items WHERE pinned_at IS NOT NULL AND rowid < ?1
                ) ORDER BY rid DESC
                """
            case .windowFloor:
                "SELECT rowid FROM items WHERE pinned_at IS NULL ORDER BY rowid DESC LIMIT 1 OFFSET ?"
            case .search:
                """
                SELECT i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app, i.pinned_at
                FROM (
                  SELECT rowid FROM items_fts WHERE items_fts MATCH ?
                  ORDER BY rowid DESC LIMIT \(SQL.searchLimit)
                ) f JOIN items i ON i.rowid = f.rowid ORDER BY f.rowid DESC
                """
            case .deleteByID: "DELETE FROM items WHERE id = ?"
            // Only ever sets a stamp: unpinning rewrites the row so it leads the history again.
            case .pin: "UPDATE items SET pinned_at = ? WHERE id = ?"
            case .staleImages:
                """
                SELECT image_path FROM items
                WHERE created_at < ? AND pinned_at IS NULL AND image_path IS NOT NULL
                """
            case .deleteStale: "DELETE FROM items WHERE created_at < ? AND pinned_at IS NULL"
            }
        }
    }

    /// `directory` defaults to the per-channel store; the harness passes a throwaway one.
    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        dbURL = base.appendingPathComponent("clipboard.sqlite3")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        open()
    }

    /// Idempotent, so the coordinator can re-open the file when the feature is switched back on.
    func open() {
        guard db == nil else { return }
        if openDatabase() { return }
        // Captured, not authored: discard a corrupt or outdated database and start over.
        closeDatabase()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
        if !openDatabase() { closeDatabase() }
    }

    /// Every accessor is statement-guarded, so a closed store answers as an empty history.
    func close() {
        setTextSearchEnabled(false)
        extractionGeneration = UUID()
        closeDatabase()
        items = []
    }

    /// Application Support, not Caches: a history the OS may reclaim is not a history.
    private static var defaultDirectory: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    // Isolated so teardown may touch the main-actor pointers; the release is already on main.
    isolated deinit {
        textSearchTask?.cancel()
        closeDatabase()
    }

    func load() {
        invalidateSearch()
        extractionGeneration = UUID()
        let floor = windowFloor()
        guard
            let loaded = withStatement(.load, { stmt in
                sqlite3_bind_int64(stmt, 1, floor)
                var loaded: [ClipboardItem] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let item = SQL.row(stmt) { loaded.append(item) }
                }
                return loaded
            })
        else { return }
        items = loaded
        // Age passes while the app isn't running; insert-time pruning alone can't catch that.
        enforceLimits()
    }

    /// The floor rowid the load reads from; 0 means no floor, so load everything.
    private func windowFloor() -> sqlite3_int64 {
        withStatement(.windowFloor) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(SQL.memoryWindow - 1))
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
        } ?? 0
    }

    func addText(_ text: String, sourceBundleID: String?) {
        if items.first?.kind == .text, items.first?.text == text { return }
        insert(ClipboardItem(text: text, sourceBundleID: sourceBundleID))
    }

    /// One row per file. Batched, so a multi-file copy prunes once rather than once per file.
    func addFiles(_ paths: [String], sourceBundleID: String?) {
        // Only a single file can be a ⌘C repeat, which is the case `addText` also guards.
        if paths.count == 1, items.first?.kind == .file, items.first?.text == paths[0] { return }
        for path in paths {
            let item = ClipboardItem(filePath: path, sourceBundleID: sourceBundleID)
            if let stmt = statements[.insert] { SQL.insert(item, with: stmt) }
            items.insert(item, at: 0)
        }
        trimWindow()
        enforceLimits()
    }

    func addImage(_ data: Data, sourceBundleID: String?) {
        let url = imagesDir.appendingPathComponent(UUID().uuidString + ".png")
        let item = ClipboardItem(imagePath: url.path, sourceBundleID: sourceBundleID)
        // The blob write is multi-MB I/O; only the row insert returns to the main actor.
        Task.detached(priority: .utility) { [weak self] in
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            await self?.insert(item)
        }
    }

    /// Bulk-insert from an import: original timestamps, external image paths, deduped.
    @discardableResult
    func importEntries(_ entries: [ClipboardItem]) -> Int {
        // Oldest first so newest ends up with the highest rowid (load orders by rowid DESC).
        let inserted = Self.importStoredItems(
            inDatabaseAt: dbURL, entries.sorted { $0.createdAt < $1.createdAt })
        load()
        return inserted
    }

    /// Move an item to the top; pasting or copying it from the palette re-recencies it.
    func promote(_ item: ClipboardItem) {
        // A pinned row holds its place, so re-recencying it would rewrite for no change.
        guard !item.isPinned, items.first?.id != item.id else { return }
        reinsert(item.with(createdAt: Date(), pinnedAt: nil))
    }

    func togglePinned(_ item: ClipboardItem) {
        // Unpinning rejoins as the newest entry. See docs/features/clipboard.md#pinned-entries.
        if item.isPinned { reinsert(item.with(createdAt: Date(), pinnedAt: nil)) } else { pin(item) }
    }

    func remove(_ item: ClipboardItem) {
        textSearchMatches.removeAll { $0.id == item.id }
        withStatement(.deleteByID) { stmt in
            SQL.bind(stmt, 1, item.id.uuidString)
            sqlite3_step(stmt)
        }
        items.removeAll { $0.id == item.id }
        deleteBlob(item)
    }

    /// A pin is a deliberate keep, so it outlives the bulk clear; `remove` is the way to drop one.
    func clearAll() {
        invalidateSearch()
        extractionGeneration = UUID()
        // RETURNING hands back the deleted blobs in the same pass, so no separate SELECT is needed.
        let orphaned = withQuery("DELETE FROM items WHERE pinned_at IS NULL RETURNING image_path") { stmt in
            var orphaned: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let path = SQL.string(stmt, 0), owns(path) { orphaned.append(path) }
            }
            return orphaned
        }
        Self.removeFiles(orphaned ?? [])
        // Every pinned row is resident however old, so the window stays whole without a reload.
        items = items.filter(\.isPinned)
    }

    @discardableResult
    func setTextSearchEnabled(_ enabled: Bool) -> Bool {
        guard enabled != textSearchEnabled else { return true }
        if enabled {
            guard let db, sqlite3_exec(db, SQL.extractionSchema, nil, nil, nil) == SQLITE_OK else {
                return false
            }
            sqlite3_exec(db, "DELETE FROM item_text_failures", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM item_text WHERE text = ''", nil, nil, nil)
        }
        textSearchEnabled = enabled
        extractionGeneration = UUID()
        invalidateSearch()
        searchRevision += 1
        return true
    }

    func nextExtractionItem(now: Date = Date()) -> ClipboardItem? {
        guard textSearchEnabled else { return nil }
        let sql = """
            SELECT \(SQL.columns)
            FROM items WHERE kind IN ('image', 'file')
              AND id NOT IN (SELECT item_id FROM item_text)
              AND id NOT IN (SELECT item_id FROM item_text_failures
                WHERE attempts >= 3 OR retry_at > ?1)
            ORDER BY rowid DESC LIMIT 1
            """
        return withQuery(sql) { stmt in
            SQL.bind(stmt, 1, now)
            return sqlite3_step(stmt) == SQLITE_ROW ? SQL.row(stmt) : nil
        }
    }

    var nextExtractionRetry: Date? {
        guard textSearchEnabled else { return nil }
        return withQuery("SELECT MIN(retry_at) FROM item_text_failures WHERE attempts < 3") { stmt in
            sqlite3_step(stmt) == SQLITE_ROW ? SQL.date(stmt, 0) : nil
        }
    }

    func recordExtractionFailure(for item: ClipboardItem, generation: UUID, retryAt: Date) {
        guard textSearchEnabled, generation == extractionGeneration else { return }
        let sql = """
            INSERT INTO item_text_failures(item_id, attempts, retry_at)
            SELECT id, 1, ?2 FROM items WHERE id = ?1
            ON CONFLICT(item_id) DO UPDATE SET attempts = attempts + 1, retry_at = excluded.retry_at
            """
        withQuery(sql) { stmt in
            SQL.bind(stmt, 1, item.id.uuidString)
            SQL.bind(stmt, 2, retryAt)
            sqlite3_step(stmt)
        }
    }

    /// Selects the row rather than naming it, so an item deleted mid-recognition stays deleted.
    @discardableResult
    func setExtractedText(_ text: String, for item: ClipboardItem, generation: UUID) -> Bool {
        guard textSearchEnabled, generation == extractionGeneration else { return false }
        let sql = """
            INSERT OR IGNORE INTO item_text(item_id, text)
            SELECT id, ?2 FROM items WHERE id = ?1 AND kind IN ('image', 'file')
            """
        let stored = withQuery(sql) { stmt in
            SQL.bind(stmt, 1, item.id.uuidString)
            SQL.bind(stmt, 2, text)
            return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
        guard stored == true else { return false }
        withQuery("DELETE FROM item_text_failures WHERE item_id = ?1") { stmt in
            SQL.bind(stmt, 1, item.id.uuidString)
            sqlite3_step(stmt)
        }
        invalidateSearch(preservingMatches: true)
        searchRevision += 1
        return true
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        item.imagePath.map { URL(filePath: $0, directoryHint: .inferFromPath) }
    }

    func fileURL(for item: ClipboardItem) -> URL? {
        item.filePath.map { URL(filePath: $0, directoryHint: .inferFromPath) }
    }

    /// Display order for `query` under `filter`: pinned entries first, each block newest-first.
    func search(_ query: String, filter: ClipboardFilter) -> [ClipboardItem] {
        // Load-bearing: a settled OCR query changes the answer without `items` changing.
        _ = searchRevision
        let q = query.trimmingCharacters(in: .whitespaces)
        updateTextSearch(q, filter: filter)
        // The filter joins the key: `rows` rebuilds per render, so a query-only memo goes stale.
        if let searchCache, searchCache.query == q, searchCache.filter == filter {
            return searchCache.result
        }
        // Filtering after the split leaves a matching pin in the Pinned section, in pin order.
        let result = filter.apply(to: unfiltered(q, filter: filter))
        searchCache = (q, filter, result)
        return result
    }

    /// Row index of `item` as currently listed, so the palette can follow a row that moved.
    func rowIndex(of item: ClipboardItem, in query: String, filter: ClipboardFilter) -> Int? {
        search(query, filter: filter).firstIndex { $0.id == item.id }
    }

    /// The Nth visible pinned entry under `query` and `filter`, where 0 is the first pinned row.
    func pinnedItem(at index: Int, in query: String, filter: ClipboardFilter) -> ClipboardItem? {
        guard index >= 0 else { return nil }
        return search(query, filter: filter).prefix(while: \.isPinned).dropFirst(index).first
    }

    /// Where a reset lands: past the pins to the newest clip, or on the first match once typed.
    func landingIndex(in query: String, filter: ClipboardFilter) -> Int {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
        return search(query, filter: filter).firstIndex { !$0.isPinned } ?? 0
    }

    func setTextSearchActive(_ active: Bool) {
        guard textSearchActive != active else { return }
        textSearchActive = active
        guard textSearchEnabled else { return }
        invalidateSearch()
        searchRevision += 1
    }

    /// Called on load, on capture and when the retention setting changes.
    func enforceLimits() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        textSearchMatches.removeAll { $0.createdAt < cutoff && !$0.isPinned }
        if let imagesStmt = statements[.staleImages], let deleteStmt = statements[.deleteStale] {
            SQL.bind(imagesStmt, 1, cutoff)
            var staleOwnedPaths: [String] = []
            while sqlite3_step(imagesStmt) == SQLITE_ROW {
                // Only delete files we own; an external reference just loses its row.
                if let path = SQL.string(imagesStmt, 0), owns(path) { staleOwnedPaths.append(path) }
            }
            sqlite3_reset(imagesStmt)
            sqlite3_clear_bindings(imagesStmt)
            SQL.bind(deleteStmt, 1, cutoff)
            sqlite3_step(deleteStmt)
            if sqlite3_changes(db) > 0 {
                invalidateSearch(preservingMatches: true)
                searchRevision += 1
            }
            sqlite3_reset(deleteStmt)
            sqlite3_clear_bindings(deleteStmt)
            Self.removeFiles(staleOwnedPaths)
        }
        // Against the oldest unpinned row: an exempt pin would make this permanently true.
        if items.last(where: { !$0.isPinned }).map({ $0.createdAt < cutoff }) == true {
            items.removeAll { $0.createdAt < cutoff && !$0.isPinned }
        }
    }

    // MARK: - Private

    private var orderedItems: [ClipboardItem] {
        if let orderedCache { return orderedCache }
        let pinned = Self.inPinOrder(items)
        // An unpinned history renders `items` as-is, so it never pays for the split.
        let result = pinned.isEmpty ? items : pinned + items.filter { !$0.isPinned }
        orderedCache = result
        return result
    }

    /// The Pinned section in pin order, so a new pin joins the end rather than the head.
    private static func inPinOrder(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantFuture) < ($1.pinnedAt ?? .distantFuture) }
    }

    /// The row keeps its place and gains a stamp, which heads the Pinned section.
    private func pin(_ item: ClipboardItem) {
        let stamp = Date()
        let pinned = (items.first { $0.id == item.id } ?? item).with(pinnedAt: stamp)
        withStatement(.pin) { stmt in
            SQL.bind(stmt, 1, stamp)
            SQL.bind(stmt, 2, item.id.uuidString)
            sqlite3_step(stmt)
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = pinned
        } else {
            // Pinned from an FTS hit outside the window, so splice it in by recency.
            let index = items.firstIndex { $0.createdAt < pinned.createdAt } ?? items.count
            items.insert(pinned, at: index)
        }
    }

    /// Rewrites the row under the same id so it leads; a delete would take its derived text too.
    private func reinsert(_ updated: ClipboardItem) {
        let sql = """
            UPDATE items SET rowid = (SELECT COALESCE(MAX(rowid), 0) + 1 FROM items),
              created_at = ?1, pinned_at = ?2 WHERE id = ?3
            """
        withQuery(sql) { stmt in
            SQL.bind(stmt, 1, updated.createdAt)
            SQL.bind(stmt, 2, updated.pinnedAt)
            SQL.bind(stmt, 3, updated.id.uuidString)
            sqlite3_step(stmt)
        }
        // Array ops also cover items surfaced by FTS from beyond the in-memory window.
        items.removeAll { $0.id == updated.id }
        items.insert(updated, at: 0)
        trimWindow()
    }

    /// Cap the in-memory window, but never drop a pinned row: those render however old they are.
    private func trimWindow() {
        guard items.count > SQL.memoryWindow, let index = items.lastIndex(where: { !$0.isPinned })
        else { return }
        items.remove(at: index)
    }

    private func insert(_ item: ClipboardItem) {
        if let stmt = statements[.insert] { SQL.insert(item, with: stmt) }
        items.insert(item, at: 0)
        trimWindow()
        enforceLimits()
    }

    /// Whether a path is inside our images directory; only those are ours to delete.
    private func owns(_ path: String) -> Bool {
        path.hasPrefix(imagesDir.path + "/")
    }

    private func deleteBlob(_ item: ClipboardItem) {
        guard let path = item.imagePath, owns(path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// A retention cut can strand hundreds of files, so they are deleted off the main actor.
    private static func removeFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        Task.detached(priority: .utility) {
            for path in paths { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    private func unfiltered(_ q: String, filter: ClipboardFilter) -> [ClipboardItem] {
        guard !q.isEmpty else { return orderedItems }
        // Pins are matched in memory: all resident, and the LIMIT would otherwise drop one.
        let ordinary = Self.inPinOrder(items).filter { $0.matches(q) } + runSearch(q).filter { !$0.isPinned }
        guard !textSearchMatches.isEmpty else { return ordinary }
        let ordinaryIDs = Set(ordinary.map(\.id))
        let additional = textSearchMatches.filter { !ordinaryIDs.contains($0.id) }
        let pins = Self.inPinOrder(ordinary + additional)
        let unpinned = ordinary.filter { !$0.isPinned }
        // OCR-only rows fill what is left of the budget the FTS `LIMIT` gives ordinary ones.
        let remaining = max(0, SQL.searchLimit - filter.apply(to: unpinned).count)
        // `Array(…)` spelled out: left open, `prefix` resolves as `Sequence` and the chain fails.
        let extra = Array(filter.apply(to: additional.filter { !$0.isPinned }).prefix(remaining))
        return pins + unpinned + extra
    }

    private func runSearch(_ q: String) -> [ClipboardItem] {
        // Trigram FTS needs ≥3 characters; shorter queries filter the in-memory window.
        guard q.count >= 3,
            let results = withStatement(.search, { stmt -> [ClipboardItem]? in
                SQL.bind(stmt, 1, SQL.phrase(q))
                var results: [ClipboardItem] = []
                var status = sqlite3_step(stmt)
                while status == SQLITE_ROW {
                    if let item = SQL.row(stmt) { results.append(item) }
                    status = sqlite3_step(stmt)
                }
                return status == SQLITE_DONE ? results : nil
            })
        else { return items.filter { $0.matches(q) } }
        return results
    }

    private func invalidateSearch(preservingMatches: Bool = false) {
        searchCache = nil
        orderedCache = nil
        textSearchTask?.cancel()
        textSearchTask = nil
        textSearchRequest = nil
        textSearchNeedsRefresh = preservingMatches && textSearchQuery != nil
        if !preservingMatches {
            textSearchQuery = nil
            textSearchFilter = nil
            textSearchMatches = []
        }
    }

    private func updateTextSearch(_ query: String, filter: ClipboardFilter) {
        guard textSearchEnabled, textSearchActive, !query.isEmpty,
            filter == .all || filter == .image || filter == .file
        else {
            if textSearchQuery != nil { invalidateSearch() }
            return
        }
        guard textSearchQuery != query || textSearchFilter != filter || textSearchNeedsRefresh else { return }
        invalidateSearch(preservingMatches: textSearchQuery == query && textSearchFilter == filter)
        textSearchNeedsRefresh = false
        textSearchQuery = query
        textSearchFilter = filter
        let request = UUID()
        textSearchRequest = request
        let url = dbURL
        let residentIDs = query.count < 3 ? Set(items.map(\.id)) : nil
        textSearchTask = Task(priority: .userInitiated) { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                SQL.extractedMatches(in: url, query: query, filter: filter, residentIDs: residentIDs)
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.textSearchRequest == request else { return }
            let previous = self.searchCache
            self.textSearchMatches = matches
            self.textSearchTask = nil
            self.searchCache = nil
            self.searchRevision += 1
            if let previous, previous.query == query {
                let current = self.search(query, filter: previous.filter)
                self.onSearchResultsChanged?(query, previous.result, current)
            }
        }
    }

    private func openDatabase() -> Bool {
        guard
            sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
                == SQLITE_OK,
            sqlite3_exec(db, SQL.schema, nil, nil, nil) == SQLITE_OK
        else { return false }
        for statement in Statement.allCases {
            statements[statement] = SQL.prepare(db, statement.sql)
        }
        return statements.count == Statement.allCases.count
    }

    private func closeDatabase() {
        statements.values.forEach { sqlite3_finalize($0) }
        statements = [:]
        sqlite3_close_v2(db)
        db = nil
    }

    /// Runs `body` on a cached statement and resets it; nil while the store is closed.
    @discardableResult
    private func withStatement<T>(_ statement: Statement, _ body: (OpaquePointer) -> T?) -> T? {
        guard let stmt = statements[statement] else { return nil }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        return body(stmt)
    }

    /// Runs `body` on a one-off statement and finalizes it; nil while the store is closed.
    @discardableResult
    private func withQuery<T>(_ sql: String, _ body: (OpaquePointer) -> T?) -> T? {
        guard let stmt = SQL.prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        return body(stmt)
    }

    /// Streams an import in off-main; a staged blob moves into `imagesDirectory`, so `owns` holds.
    nonisolated static func importStoredItems(
        inDatabaseAt url: URL, adoptingImagesInto imagesDirectory: URL? = nil,
        _ items: some Sequence<ClipboardItem>
    ) -> Int {
        var keys: Set<Int> = []
        forEachStoredItem(inDatabaseAt: url) { keys.insert(importKey($0)) }
        guard let db = SQL.connect(to: url) else { return 0 }
        defer { sqlite3_close_v2(db) }
        // A capture from the poller can hold the write lock; without this the import truncates.
        sqlite3_busy_timeout(db, 5_000)
        guard let stmt = SQL.prepare(db, SQL.insertSQL) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var inserted = 0
        // One transaction for the batch: ~1 WAL commit rather than one per row.
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for staged in items {
            let item = adoptionTarget(staged, in: imagesDirectory)
            guard keys.insert(importKey(item)).inserted else { continue }
            if item.imagePath != staged.imagePath, !moveBlob(from: staged.imagePath, to: item.imagePath) {
                continue
            }
            SQL.insert(item, with: stmt)
            inserted += 1
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return inserted
    }

    /// Past the memory window, off-main, oldest first so a streaming import keeps the order.
    nonisolated static func forEachStoredItem(inDatabaseAt url: URL, _ body: (ClipboardItem) -> Void) {
        guard let db = SQL.connect(to: url) else { return }
        defer { sqlite3_close_v2(db) }
        guard let stmt = SQL.prepare(db, "SELECT \(SQL.columns) FROM items ORDER BY rowid") else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = SQL.row(stmt) { body(item) }
        }
    }

    /// Hashed, never held: a whole history's text must not sit in memory to dedupe an import.
    nonisolated private static func importKey(_ item: ClipboardItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.kind)
        // Keyed off `text` for everything but an image, or every file entry hashes alike.
        hasher.combine(item.kind == .image ? item.imagePath : item.text)
        return hasher.finalize()
    }

    /// Keeps the staged blob's name, so a backup imported twice dedupes on the same path.
    nonisolated private static func adoptionTarget(
        _ item: ClipboardItem, in directory: URL?
    ) -> ClipboardItem {
        guard let directory, item.kind == .image, let path = item.imagePath else { return item }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return ClipboardItem(
            id: item.id, kind: .image, text: nil,
            imagePath: directory.appendingPathComponent(name).path, createdAt: item.createdAt,
            sourceBundleID: item.sourceBundleID, pinnedAt: item.pinnedAt)
    }

    /// false leaves the row out, so none ever points into a staging tree about to be discarded.
    nonisolated private static func moveBlob(from source: String?, to destination: String?) -> Bool {
        guard let source, let destination else { return false }
        let from = URL(fileURLWithPath: source)
        let to = URL(fileURLWithPath: destination)
        return (try? FileManager.default.moveItem(at: from, to: to)) != nil
            || (try? FileManager.default.copyItem(at: from, to: to)) != nil
    }
}

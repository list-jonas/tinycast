import Foundation
import SQLite3

/// SQL, row codec and the off-main connections the clipboard's reads and imports share.
enum ClipboardDatabase {
    // Spelled as the C macro in sqlite3.h, which isn't imported into Swift.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let memoryWindow = 1000
    /// The most unpinned rows any one query answers with, ordinary and OCR-only alike.
    static let searchLimit = 200

    static let columns = "id, kind, text, image_path, created_at, source_app, pinned_at"
    static let insertSQL = "INSERT INTO items(\(columns)) VALUES(?,?,?,?,?,?,?)"

    static let schema = """
        CREATE TABLE IF NOT EXISTS items(
          id TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL,
          text TEXT,
          image_path TEXT,
          created_at REAL NOT NULL,
          source_app TEXT,
          pinned_at REAL
        );
        CREATE INDEX IF NOT EXISTS items_created_at ON items(created_at);
        CREATE INDEX IF NOT EXISTS items_pinned_at ON items(pinned_at) WHERE pinned_at IS NOT NULL;
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
          text, content='items', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
          INSERT INTO items_fts(rowid, text) VALUES(new.rowid, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, text) VALUES('delete', old.rowid, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF rowid, text ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, text) VALUES('delete', old.rowid, old.text);
          INSERT INTO items_fts(rowid, text) VALUES(new.rowid, new.text);
        END;
        """

    static let extractionSchema = """
        CREATE TABLE IF NOT EXISTS item_text(
          item_id TEXT NOT NULL UNIQUE, text TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS item_text_fts USING fts5(
          text, content='item_text', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS item_text_ai AFTER INSERT ON item_text BEGIN
          INSERT INTO item_text_fts(rowid, text) VALUES(new.rowid, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS item_text_ad AFTER DELETE ON item_text BEGIN
          INSERT INTO item_text_fts(item_text_fts, rowid, text)
            VALUES('delete', old.rowid, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_extract_ad AFTER DELETE ON items BEGIN
          DELETE FROM item_text WHERE item_id = old.id;
        END;
        CREATE TABLE IF NOT EXISTS item_text_failures(
          item_id TEXT NOT NULL UNIQUE, attempts INTEGER NOT NULL, retry_at REAL NOT NULL
        );
        CREATE TRIGGER IF NOT EXISTS items_extract_failure_ad AFTER DELETE ON items BEGIN
          DELETE FROM item_text_failures WHERE item_id = old.id;
        END;
        CREATE INDEX IF NOT EXISTS items_extract_candidates ON items(kind)
          WHERE kind IN ('image', 'file');
        """

    /// A second connection. `READWRITE` because a WAL reader still writes `-shm`.
    static func connect(to url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        return db
    }

    static func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK ? stmt : nil
    }

    static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text {
            sqlite3_bind_text(stmt, index, text, -1, transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ date: Date?) {
        if let date {
            sqlite3_bind_double(stmt, index, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// One FTS5 phrase, so a typed quote or operator is matched rather than parsed.
    static func phrase(_ query: String) -> String {
        "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func insert(_ item: ClipboardItem, with stmt: OpaquePointer?) {
        bind(stmt, 1, item.id.uuidString)
        bind(stmt, 2, item.kind.rawValue)
        bind(stmt, 3, item.text)
        bind(stmt, 4, item.imagePath)
        bind(stmt, 5, item.createdAt)
        bind(stmt, 6, item.sourceBundleID)
        bind(stmt, 7, item.pinnedAt)
        sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    static func row(_ stmt: OpaquePointer?) -> ClipboardItem? {
        guard let id = string(stmt, 0).flatMap(UUID.init(uuidString:)),
            let kind = string(stmt, 1).flatMap(ClipboardItem.Kind.init(rawValue:))
        else { return nil }
        return ClipboardItem(
            id: id, kind: kind, text: string(stmt, 2), imagePath: string(stmt, 3),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
            sourceBundleID: string(stmt, 5), pinnedAt: date(stmt, 6))
    }

    static func date(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    static func string(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }

    /// OCR-only matches, read on a connection of their own so a search never waits on the main one.
    static func extractedMatches(
        in url: URL, query: String, filter: ClipboardFilter, residentIDs: Set<UUID>?
    ) -> [ClipboardItem] {
        guard let db = connect(to: url) else { return [] }
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, "PRAGMA cache_size=-2048", nil, nil, nil)
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        let isShort = query.count < 3
        let kind = filter == .image ? "i.kind = 'image'" : filter == .file ? "i.kind = 'file'" : "1"
        let columns = "i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app, i.pinned_at"
        let sql =
            isShort
            ? """
            SELECT \(columns), t.text FROM item_text t JOIN items i ON i.id = t.item_id
            WHERE \(kind) AND (i.pinned_at IS NOT NULL OR i.rowid >= COALESCE(
              (SELECT rowid FROM items WHERE pinned_at IS NULL ORDER BY rowid DESC LIMIT 1 OFFSET \(memoryWindow - 1)), 0))
            ORDER BY i.pinned_at IS NULL, i.pinned_at, i.rowid DESC
            """
            : """
            SELECT * FROM (
              SELECT \(columns), NULL AS recognized, i.rowid AS rid FROM items i
                WHERE i.pinned_at IS NULL AND i.rowid IN (
                SELECT i.rowid FROM item_text_fts f
                  JOIN item_text t ON t.rowid = f.rowid JOIN items i ON i.id = t.item_id
                WHERE item_text_fts MATCH ?1 AND \(kind)
                ORDER BY i.rowid DESC
                LIMIT \(searchLimit) + (SELECT COUNT(*) FROM items WHERE pinned_at IS NOT NULL)
              )
              UNION ALL
              SELECT \(columns), t.text AS recognized, i.rowid AS rid
                FROM items i JOIN item_text t ON t.item_id = i.id
                WHERE i.pinned_at IS NOT NULL AND \(kind)
            ) ORDER BY pinned_at IS NULL, pinned_at, rid DESC
            """
        guard let stmt = prepare(db, sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        if !isShort { bind(stmt, 1, phrase(query)) }
        var matches: [ClipboardItem] = []
        var unpinned = 0
        while !Task.isCancelled, sqlite3_step(stmt) == SQLITE_ROW {
            guard let item = row(stmt) else { continue }
            if let residentIDs, !residentIDs.contains(item.id) { continue }
            if isShort || item.isPinned,
                string(stmt, 7)?.localizedCaseInsensitiveContains(query) != true
            {
                continue
            }
            matches.append(item)
            if !item.isPinned { unpinned += 1 }
            if unpinned == searchLimit { break }
        }
        return Task.isCancelled ? [] : matches
    }
}

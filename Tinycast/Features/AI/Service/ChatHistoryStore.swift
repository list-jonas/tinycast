import Foundation
import Observation
import SQLite3

private let chatSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum SQLValue {
    case text(String?)
    case int(Int?)
    case real(Double?)
    case blob(Data)
}

/// Durable local chats; summaries stay resident while transcripts load only when requested.
@MainActor
@Observable
final class ChatHistoryStore {
    private(set) var conversations: [ChatConversation] = []
    private(set) var isAvailable = true

    private static let schema = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS conversations(
          id TEXT PRIMARY KEY NOT NULL,
          title TEXT NOT NULL,
          preview TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          message_count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS messages(
          id TEXT PRIMARY KEY NOT NULL,
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          role TEXT NOT NULL,
          text TEXT NOT NULL,
          state TEXT NOT NULL,
          sent_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS message_images(
          message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          mime_type TEXT NOT NULL,
          data BLOB NOT NULL,
          PRIMARY KEY(message_id, position)
        );
        CREATE TABLE IF NOT EXISTS message_documents(
          message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          name TEXT NOT NULL,
          mime_type TEXT NOT NULL,
          data BLOB NOT NULL,
          PRIMARY KEY(message_id, position)
        );
        CREATE TABLE IF NOT EXISTS message_searches(
          message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          query TEXT,
          text_offset INTEGER NOT NULL,
          PRIMARY KEY(message_id, position)
        );
        CREATE TABLE IF NOT EXISTS message_tools(
          message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          call_id TEXT NOT NULL,
          origin TEXT NOT NULL,
          title TEXT NOT NULL,
          state TEXT NOT NULL,
          text_offset INTEGER NOT NULL,
          PRIMARY KEY(message_id, position)
        );
        CREATE TABLE IF NOT EXISTS conversation_details(
          conversation_id TEXT PRIMARY KEY NOT NULL
            REFERENCES conversations(id) ON DELETE CASCADE,
          custom_title TEXT,
          generated_title TEXT,
          pinned INTEGER NOT NULL DEFAULT 0,
          model TEXT
        );
        CREATE TABLE IF NOT EXISTS message_details(
          message_id TEXT PRIMARY KEY NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          tool_scope TEXT,
          input_tokens INTEGER,
          output_tokens INTEGER,
          cached_tokens INTEGER,
          reasoning_tokens INTEGER,
          context_window INTEGER,
          cost_usd REAL
        );
        CREATE TABLE IF NOT EXISTS message_thinking(
          message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          position INTEGER NOT NULL,
          text TEXT NOT NULL,
          text_offset INTEGER NOT NULL,
          duration REAL,
          PRIMARY KEY(message_id, position)
        );
        CREATE INDEX IF NOT EXISTS messages_by_conversation
          ON messages(conversation_id, position);
        CREATE INDEX IF NOT EXISTS conversations_by_recency
          ON conversations(updated_at DESC);
        """

    @ObservationIgnored private let databaseURL: URL
    @ObservationIgnored private var database: OpaquePointer?

    init(directory: URL) {
        databaseURL = directory.appendingPathComponent("ai-chats.sqlite3")
    }

    isolated deinit {
        sqlite3_close(database)
    }

    func load() {
        guard ensureDatabase() else { return }
        let sql = """
            SELECT c.id, c.title, c.preview, c.created_at, c.updated_at, c.message_count,
              m.custom_title, COALESCE(m.pinned, 0), m.generated_title
            FROM conversations c
            LEFT JOIN conversation_details m ON m.conversation_id = c.id
            ORDER BY c.updated_at DESC;
            """
        var loaded: [ChatConversation] = []
        let read = query(sql, []) { row in
            guard let id = UUID(uuidString: Self.text(row, 0)) else { return }
            loaded.append(
                ChatConversation(
                    id: id, title: Self.text(row, 1), preview: Self.text(row, 2),
                    createdAt: Self.date(row, 3), updatedAt: Self.date(row, 4),
                    messageCount: Self.int(row, 5) ?? 0, customTitle: Self.optionalText(row, 6),
                    isPinned: Self.int(row, 7) != 0, generatedTitle: Self.optionalText(row, 8)))
        }
        if read { conversations = loaded }
    }

    /// Off means fully off: the handle and the resident summaries go, the file on disk stays.
    func close() {
        sqlite3_close(database)
        database = nil
        conversations = []
    }

    func search(_ query: String) -> [ChatConversation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.preview.localizedCaseInsensitiveContains(query)
        }
    }

    func conversation(id: UUID) -> ChatConversation? {
        conversations.first { $0.id == id }
    }

    /// A blank name hands the title back to the first question rather than storing an empty one.
    func rename(id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.titleLimit))
        guard var conversation = conversation(id: id),
            write(.customTitle(custom), of: id)
        else { return }
        conversation.customTitle = custom
        replace(conversation)
    }

    /// The harness's name for a chat; stored beside it, so a later save cannot derive it away.
    func setGeneratedTitle(_ title: String, id: UUID) {
        guard var conversation = conversation(id: id), write(.generatedTitle(title), of: id)
        else { return }
        conversation.generatedTitle = title
        replace(conversation)
    }

    func setPinned(_ pinned: Bool, id: UUID) {
        guard var conversation = conversation(id: id), conversation.isPinned != pinned,
            write(.pinned(pinned), of: id)
        else { return }
        conversation.isPinned = pinned
        replace(conversation)
    }

    private static let titleLimit = 120

    func session(id: UUID) -> ChatSession? {
        guard ensureDatabase() else { return nil }
        let key = SQLValue.text(id.uuidString)
        var dates: (created: Date, updated: Date)?
        query("SELECT created_at, updated_at FROM conversations WHERE id = ? LIMIT 1;", [key]) {
            dates = (Self.date($0, 0), Self.date($0, 1))
        }
        guard let dates else { return nil }
        let images = children(
            "SELECT i.message_id, i.mime_type, i.data FROM message_images i", of: id, order: "i"
        ) { row in Self.blob(row, 2).map { AIImage(data: $0, mimeType: Self.text(row, 1)) } }
        let documents = children(
            "SELECT d.message_id, d.name, d.mime_type, d.data FROM message_documents d", of: id,
            order: "d"
        ) { row in
            Self.blob(row, 3).map {
                AIDocument(data: $0, mimeType: Self.text(row, 2), name: Self.text(row, 1))
            }
        }
        // A stored search is always finished: only a live reply has one in progress.
        let searches = children(
            "SELECT s.message_id, s.query, s.text_offset, s.position FROM message_searches s",
            of: id, order: "s"
        ) { row in
            ChatSearch(
                query: Self.optionalText(row, 1), isComplete: true,
                textOffset: Self.int(row, 2) ?? 0, sequence: Self.int(row, 3) ?? 0)
        }
        // A call left running belonged to a process that is gone, so it never reported back.
        let toolUses = children(
            """
            SELECT t.message_id, t.call_id, t.origin, t.title, t.state, t.text_offset, t.position
            FROM message_tools t
            """, of: id, order: "t"
        ) { row in
            let stored = ChatToolUse.State(rawValue: Self.text(row, 4)) ?? .failed
            return ChatToolUse(
                callID: Self.text(row, 1), origin: Self.text(row, 2), title: Self.text(row, 3),
                state: stored == .running ? .failed : stored, textOffset: Self.int(row, 5) ?? 0,
                sequence: Self.int(row, 6) ?? 0)
        }
        let reasoning = children(
            "SELECT r.message_id, r.text, r.text_offset, r.duration FROM message_thinking r",
            of: id, order: "r"
        ) { row in
            ChatReasoning(
                text: Self.text(row, 1), textOffset: Self.int(row, 2) ?? 0,
                duration: Self.real(row, 3))
        }
        // A row with no usage column set is a scope alone: the reply reported nothing.
        let meta = children(
            """
            SELECT x.message_id, x.tool_scope, x.input_tokens, x.output_tokens, x.cached_tokens,
              x.reasoning_tokens, x.context_window, x.cost_usd
            FROM message_details x
            """, of: id, order: nil
        ) { row -> (toolScope: String?, usage: AIUsage?) in
            let usage = AIUsage(
                inputTokens: Self.int(row, 2), outputTokens: Self.int(row, 3),
                cachedInputTokens: Self.int(row, 4), reasoningTokens: Self.int(row, 5),
                contextWindow: Self.int(row, 6), costUSD: Self.real(row, 7))
            return (Self.optionalText(row, 1), usage == AIUsage() ? nil : usage)
        }
        let messageSQL = """
            SELECT id, role, text, state, sent_at FROM messages
            WHERE conversation_id = ? ORDER BY position;
            """
        var messages: [ChatMessage] = []
        let read = query(messageSQL, [key]) { row in
            guard
                let messageID = UUID(uuidString: Self.text(row, 0)),
                let role = ChatMessage.Role(rawValue: Self.text(row, 1)),
                let stored = ChatMessage.State(rawValue: Self.text(row, 3))
            else { return }
            let body = Self.text(row, 2)
            let interrupted = stored == .streaming
            let details = meta[messageID]?.first
            messages.append(
                ChatMessage(
                    id: messageID, role: role,
                    text: interrupted && body.isEmpty ? "Response interrupted." : body,
                    state: interrupted ? .failed : stored, sentAt: Self.date(row, 4),
                    images: images[messageID] ?? [], documents: documents[messageID] ?? [],
                    searches: searches[messageID] ?? [], toolUses: toolUses[messageID] ?? [],
                    reasoning: reasoning[messageID] ?? [],
                    usage: details?.usage, toolScope: details?.toolScope))
        }
        guard read else { return nil }
        return ChatSession(
            id: id, createdAt: dates.created, updatedAt: dates.updated, messages: messages,
            model: model(forConversation: id))
    }

    func save(_ session: ChatSession) {
        guard !session.messages.isEmpty, ensureDatabase(), let database else { return }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        guard saveConversation(session), rewriteTail(of: session), saveModel(of: session)
        else {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            return
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            return
        }
        var summary = session.summary
        // The summary is derived afresh; a rename and a pin are the reader's, so they carry over.
        if let existing = conversation(id: session.id) {
            summary.customTitle = existing.customTitle
            summary.isPinned = existing.isPinned
            summary.generatedTitle = existing.generatedTitle
        }
        replace(summary)
    }

    private func replace(_ conversation: ChatConversation) {
        var updated = conversations.filter { $0.id != conversation.id }
        updated.append(conversation)
        conversations = updated.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// One fact a conversation's meta row holds; writing one never touches the others.
    private enum Meta {
        case customTitle(String?)
        case generatedTitle(String)
        case pinned(Bool)
        case model(AIModelSelection)
    }

    private func write(_ meta: Meta, of id: UUID) -> Bool {
        guard ensureDatabase() else { return false }
        let column: String
        let value: SQLValue
        switch meta {
        case .customTitle(let title): (column, value) = ("custom_title", .text(title))
        case .generatedTitle(let title): (column, value) = ("generated_title", .text(title))
        case .pinned(let pinned): (column, value) = ("pinned", .int(pinned ? 1 : 0))
        case .model(let model):
            guard let json = try? JSONEncoder().encode(model),
                let encoded = String(bytes: json, encoding: .utf8)
            else { return false }
            (column, value) = ("model", .text(encoded))
        }
        return run(
            """
            INSERT INTO conversation_details(conversation_id, \(column)) VALUES(?, ?)
            ON CONFLICT(conversation_id) DO UPDATE SET \(column) = excluded.\(column);
            """, [[.text(id.uuidString), value]])
    }

    func remove(id: UUID) {
        guard ensureDatabase(),
            run("DELETE FROM conversations WHERE id = ?;", [[.text(id.uuidString)]])
        else { return }
        conversations.removeAll { $0.id == id }
    }

    /// Pinned chats are the ones the reader asked to keep, so clearing the rest spares them.
    func clearAll() {
        guard ensureDatabase(),
            sqlite3_exec(
                database, "DELETE FROM conversations WHERE id NOT IN (\(Self.pinnedIDs))", nil,
                nil, nil) == SQLITE_OK
        else { return }
        conversations.removeAll { !$0.isPinned }
    }

    private static let pinnedIDs =
        "SELECT conversation_id FROM conversation_details WHERE pinned = 1"

    /// Inline BLOBs make this the one store where a delete frees pages without shrinking the file.
    @discardableResult
    func prune(before cutoff: Date) -> Int {
        guard ensureDatabase(),
            run(
                "DELETE FROM conversations WHERE updated_at < ? AND id NOT IN (\(Self.pinnedIDs));",
                [[.real(cutoff.timeIntervalSince1970)]])
        else { return 0 }
        let removed = Int(sqlite3_changes(database))
        guard removed > 0 else { return 0 }
        sqlite3_exec(database, "VACUUM", nil, nil, nil)
        conversations.removeAll { $0.updatedAt < cutoff && !$0.isPinned }
        return removed
    }

    private func ensureDatabase() -> Bool {
        if database != nil { return true }
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            isAvailable = false
            return false
        }
        guard
            sqlite3_open_v2(
                databaseURL.path, &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
            sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
                == SQLITE_OK,
            sqlite3_exec(database, Self.schema, nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_close(database)
            database = nil
            isAvailable = false
            return false
        }
        isAvailable = true
        return true
    }

    private func saveConversation(_ session: ChatSession) -> Bool {
        let summary = session.summary
        return run(
            """
            INSERT INTO conversations(id, title, preview, created_at, updated_at, message_count)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              title = excluded.title,
              preview = excluded.preview,
              updated_at = excluded.updated_at,
              message_count = excluded.message_count;
            """,
            [[
                .text(summary.id.uuidString), .text(summary.title), .text(summary.preview),
                .real(summary.createdAt.timeIntervalSince1970),
                .real(summary.updatedAt.timeIntervalSince1970), .int(summary.messageCount)
            ]])
    }

    /// A session only appends or replaces its last, so a save rewrites the stored tail alone.
    private func rewriteTail(of session: ChatSession) -> Bool {
        let key = SQLValue.text(session.id.uuidString)
        var stored = 0
        query("SELECT COUNT(*) FROM messages WHERE conversation_id = ?;", [key]) {
            stored = Self.int($0, 0) ?? 0
        }
        // A store holding more rows than memory is foreign state; rewrite it whole, never splice.
        let rewriteFrom = stored > session.messages.count ? 0 : max(stored - 1, 0)
        let tail = session.messages.enumerated().dropFirst(rewriteFrom)
        guard
            run(
                "DELETE FROM messages WHERE conversation_id = ? AND position >= ?;",
                [[key, .int(rewriteFrom)]]),
            run(
                """
                INSERT INTO messages(id, conversation_id, position, role, text, state, sent_at)
                VALUES(?, ?, ?, ?, ?, ?, ?);
                """,
                tail.map { position, message in
                    [
                        .text(message.id.uuidString), key, .int(position),
                        .text(message.role.rawValue), .text(message.text),
                        .text(message.state.rawValue), .real(message.sentAt.timeIntervalSince1970)
                    ]
                })
        else { return false }
        return tail.allSatisfy { saveDetails(of: $0.element) }
    }

    private func saveDetails(of message: ChatMessage) -> Bool {
        let id = SQLValue.text(message.id.uuidString)
        let usage = message.usage
        return run(
            "INSERT INTO message_images(message_id, position, mime_type, data) VALUES(?, ?, ?, ?);",
            message.images.enumerated().map { [id, .int($0), .text($1.mimeType), .blob($1.data)] })
            && run(
                """
                INSERT INTO message_documents(message_id, position, name, mime_type, data)
                VALUES(?, ?, ?, ?, ?);
                """,
                message.documents.enumerated().map {
                    [id, .int($0), .text($1.name), .text($1.mimeType), .blob($1.data)]
                })
            && run(
                """
                INSERT INTO message_searches(message_id, position, query, text_offset)
                VALUES(?, ?, ?, ?);
                """,
                message.searches.map { [id, .int($0.sequence), .text($0.query), .int($0.textOffset)] })
            && run(
                """
                INSERT INTO message_tools(
                  message_id, position, call_id, origin, title, state, text_offset)
                VALUES(?, ?, ?, ?, ?, ?, ?);
                """,
                message.toolUses.map {
                    [
                        id, .int($0.sequence), .text($0.callID), .text($0.origin), .text($0.title),
                        .text($0.state.rawValue), .int($0.textOffset)
                    ]
                })
            && run(
                """
                INSERT INTO message_thinking(message_id, position, text, text_offset, duration)
                VALUES(?, ?, ?, ?, ?);
                """,
                message.reasoning.enumerated().map {
                    [id, .int($0), .text($1.text), .int($1.textOffset), .real($1.duration)]
                })
            // Only a message with a scope or a usage report writes a row.
            && run(
                """
                INSERT INTO message_details(message_id, tool_scope, input_tokens, output_tokens,
                  cached_tokens, reasoning_tokens, context_window, cost_usd)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?);
                """,
                message.toolScope == nil && usage == nil
                    ? []
                    : [[
                        id, .text(message.toolScope), .int(usage?.inputTokens),
                        .int(usage?.outputTokens), .int(usage?.cachedInputTokens),
                        .int(usage?.reasoningTokens), .int(usage?.contextWindow),
                        .real(usage?.costUSD)
                    ]])
    }

    /// After the conversation's row, which the meta row references; a chat with no pick has none.
    private func saveModel(of session: ChatSession) -> Bool {
        guard let model = session.model else { return true }
        return write(.model(model), of: session.id)
    }

    /// A route removed since is the coordinator's to repair; an unreadable one is simply absent.
    private func model(forConversation id: UUID) -> AIModelSelection? {
        var model: AIModelSelection?
        query(
            "SELECT model FROM conversation_details WHERE conversation_id = ? AND model IS NOT NULL;",
            [.text(id.uuidString)]
        ) { model = try? JSONDecoder().decode(AIModelSelection.self, from: Data(Self.text($0, 0).utf8)) }
        return model
    }

    /// A chat already saved changes model between turns; one not yet saved takes it on its first.
    func setModel(_ model: AIModelSelection, id: UUID) {
        guard conversation(id: id) != nil else { return }
        _ = write(.model(model), of: id)
    }

    // MARK: - SQLite

    /// Rows of one table keyed by message, for every message of one conversation.
    private func children<T>(
        _ select: String, of id: UUID, order alias: String?, _ make: (OpaquePointer) -> T?
    ) -> [UUID: [T]] {
        let table = alias ?? "x"
        let order = alias.map { " ORDER BY \($0).message_id, \($0).position" } ?? ""
        let sql = """
            \(select)
            JOIN messages m ON m.id = \(table).message_id
            WHERE m.conversation_id = ?\(order);
            """
        var rows: [UUID: [T]] = [:]
        query(sql, [.text(id.uuidString)]) { row in
            guard let messageID = UUID(uuidString: Self.text(row, 0)), let value = make(row)
            else { return }
            rows[messageID, default: []].append(value)
        }
        return rows
    }

    @discardableResult
    private func query(_ sql: String, _ values: [SQLValue], _ row: (OpaquePointer) -> Void) -> Bool {
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        guard bind(values, to: statement) else { return false }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        return true
    }

    /// One statement stepped once per row; no rows is a success that never touches the database.
    private func run(_ sql: String, _ rows: [[SQLValue]]) -> Bool {
        guard !rows.isEmpty else { return true }
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        for values in rows {
            guard bind(values, to: statement), sqlite3_step(statement) == SQLITE_DONE else {
                return false
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        return true
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard let database, sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
        else { return nil }
        return statement
    }

    /// A nil value is left unbound, which SQLite reads as NULL.
    private func bind(_ values: [SQLValue], to statement: OpaquePointer) -> Bool {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text?): sqlite3_bind_text(statement, index, text, -1, chatSQLiteTransient)
            case .int(let number?): sqlite3_bind_int64(statement, index, Int64(number))
            case .real(let number?): sqlite3_bind_double(statement, index, number)
            case .blob(let data):
                let bound = data.withUnsafeBytes {
                    sqlite3_bind_blob(
                        statement, index, $0.baseAddress, Int32($0.count), chatSQLiteTransient)
                }
                guard bound == SQLITE_OK else { return false }
            case .text(nil), .int(nil), .real(nil): continue
            }
        }
        return true
    }

    private static func isNull(_ row: OpaquePointer, _ index: Int32) -> Bool {
        sqlite3_column_type(row, index) == SQLITE_NULL
    }

    private static func text(_ row: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(row, index).map { String(cString: $0) } ?? ""
    }

    private static func optionalText(_ row: OpaquePointer, _ index: Int32) -> String? {
        isNull(row, index) ? nil : text(row, index)
    }

    private static func int(_ row: OpaquePointer, _ index: Int32) -> Int? {
        isNull(row, index) ? nil : Int(sqlite3_column_int64(row, index))
    }

    private static func real(_ row: OpaquePointer, _ index: Int32) -> Double? {
        isNull(row, index) ? nil : sqlite3_column_double(row, index)
    }

    private static func date(_ row: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(row, index))
    }

    /// A zero-length blob reads as no pointer, and such an attachment is dropped as before.
    private static func blob(_ row: OpaquePointer, _ index: Int32) -> Data? {
        sqlite3_column_blob(row, index).map {
            Data(bytes: $0, count: Int(sqlite3_column_bytes(row, index)))
        }
    }
}

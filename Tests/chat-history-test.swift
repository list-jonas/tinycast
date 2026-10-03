import Foundation
import SQLite3

@main
@MainActor
struct ChatHistoryTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        historyRoundTripsAndRepairsInterruptedReplies()
        savesRewriteOnlyTheStoredTail()
        crashRepairSurvivesTailSaves()
        retentionPrunesByAgeAndCascades()
        toolUsesPersistAndSettleOnReload()
        renamesAndPinsSurviveSavesAndSpareRetention()
        titlesAreCleanedAndNeverBeatARename()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func toolUsesPersistAndSettleOnReload() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ai-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ChatHistoryStore(directory: directory)
        var session = ChatSession()
        session.append(ChatMessage(role: .user, text: "go"))
        session.append(
            ChatMessage(
                role: .assistant, text: "working", state: .complete,
                toolUses: [
                    ChatToolUse(
                        callID: "c1", origin: "Files", title: "read", state: .completed,
                        textOffset: 3, sequence: 0),
                    ChatToolUse(
                        callID: "c2", origin: "Files", title: "write", state: .running,
                        textOffset: 7, sequence: 1)
                ]))
        session.append(ChatMessage(role: .user, text: "list my PRs", toolScope: "github"))
        session.append(ChatMessage(role: .assistant, text: "Two open."))
        store.save(session)

        let reloaded = ChatHistoryStore(directory: directory).session(id: session.id)
        expect(
            reloaded?.messages[2].toolScope == "github" && reloaded?.messages[0].toolScope == nil,
            "a question addressed to one server still names it after reopening, so Regenerate does too")
        let uses = reloaded?.messages[1].toolUses ?? []
        expect(uses.count == 2, "a reopened chat still shows what the model did on the reader's behalf")
        expect(uses.first?.title == "read", "in the order it did it")
        expect(
            uses.last?.state == .failed,
            "a call left running belonged to a process that is gone, so it never reported back")
    }

    static func historyRoundTripsAndRepairsInterruptedReplies() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ai-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_000)
        var session = ChatSession(id: id, createdAt: created)
        let picture = AIImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        session.append(ChatMessage(role: .user, text: "Hello", sentAt: created, images: [picture]))
        session.append(
            ChatMessage(
                role: .assistant, text: "Partial", state: .streaming,
                sentAt: created.addingTimeInterval(1),
                searches: [ChatSearch(query: "india news", isComplete: false, textOffset: 3, sequence: 0)]))
        expect(
            session.messages.last?.segments == [
                .text("Par"),
                .search(ChatSearch(query: "india news", isComplete: false, textOffset: 3, sequence: 0)),
                .text("tial")
            ],
            "a search splits the reply where it happened")

        let store = ChatHistoryStore(directory: directory)
        store.save(session)
        expect(store.conversations.count == 1, "saving creates one conversation summary")
        expect(store.search("hello").first?.id == id, "history searches title and preview")

        let reopened = ChatHistoryStore(directory: directory)
        reopened.load()
        let loaded = reopened.session(id: id)
        expect(loaded?.messages.count == 2, "a transcript survives reopening")
        expect(loaded?.messages.first?.images == [picture], "attached images survive reopening")
        expect(
            loaded?.messages.last?.searches
                == [ChatSearch(query: "india news", isComplete: true, textOffset: 3, sequence: 0)],
            "searches survive reopening and are always finished")
        expect(
            session.requestMessages().first?.images == [picture],
            "attached images travel with the request")
        expect(loaded?.messages.last?.state == .failed, "an interrupted stream is repaired")
        expect(
            loaded?.messages.last?.text == "Partial",
            "an interrupted partial answer is preserved")

        reopened.remove(id: id)
        expect(reopened.conversations.isEmpty, "deleting a chat removes its summary")
        expect(reopened.session(id: id) == nil, "deleting a chat cascades to its messages")
    }

    static func savesRewriteOnlyTheStoredTail() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ai-tail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let created = Date(timeIntervalSince1970: 2_000)
        var session = ChatSession(id: id, createdAt: created)
        let picture = AIImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        session.append(ChatMessage(role: .user, text: "First", sentAt: created, images: [picture]))
        session.append(
            ChatMessage(role: .assistant, text: "Reply one", sentAt: created.addingTimeInterval(1)))
        let store = ChatHistoryStore(directory: directory)
        store.save(session)

        let database = directory.appendingPathComponent("ai-chats.sqlite3")
        expect(
            tamper(database, "UPDATE messages SET text = 'tampered' WHERE position = 0;")
                && tamper(database, "UPDATE message_images SET mime_type = 'tampered/x';"),
            "the harness can mark stored rows behind the store's back")

        session.append(
            ChatMessage(role: .user, text: "Second", sentAt: created.addingTimeInterval(2)))
        session.append(
            ChatMessage(
                role: .assistant, text: "", state: .streaming,
                sentAt: created.addingTimeInterval(3)))
        store.save(session)
        if var reply = session.messages.last {
            reply.text = "Reply two"
            reply.state = .complete
            reply.searches = [ChatSearch(query: "docs", isComplete: true, textOffset: 0, sequence: 0)]
            session.replaceLast(with: reply)
        }
        store.save(session)
        store.save(session)

        let loaded = ChatHistoryStore(directory: directory).session(id: id)
        expect(loaded?.messages.count == 4, "repeated saves never duplicate messages")
        expect(loaded?.messages.first?.text == "tampered", "settled rows are never rewritten")
        expect(
            loaded?.messages.first?.images.first?.mimeType == "tampered/x",
            "an image blob is written once, not on every save")
        expect(loaded?.messages.last?.text == "Reply two", "the mutable tail row is rewritten")
        expect(
            loaded?.messages.last?.searches
                == [ChatSearch(query: "docs", isComplete: true, textOffset: 0, sequence: 0)],
            "tail searches reinsert without tripping their primary key")

        expect(
            tamper(
                database,
                """
                INSERT INTO messages(id, conversation_id, position, role, text, state, sent_at)
                VALUES('ghost', '\(id.uuidString)', 9, 'assistant', 'ghost', 'complete', 0);
                """),
            "the harness can plant a foreign stored row")
        store.save(session)
        let reconciled = ChatHistoryStore(directory: directory).session(id: id)
        expect(
            reconciled?.messages.count == 4 && reconciled?.messages.first?.text == "First",
            "a store holding more rows than memory is rewritten whole")
    }

    static func crashRepairSurvivesTailSaves() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ai-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let created = Date(timeIntervalSince1970: 3_000)
        var session = ChatSession(id: id, createdAt: created)
        session.append(ChatMessage(role: .user, text: "Ask", sentAt: created))
        session.append(
            ChatMessage(
                role: .assistant, text: "Cut", state: .streaming,
                sentAt: created.addingTimeInterval(1),
                searches: [ChatSearch(query: "news", isComplete: false, textOffset: 1, sequence: 0)]))
        ChatHistoryStore(directory: directory).save(session)

        let reopened = ChatHistoryStore(directory: directory)
        guard let repaired = reopened.session(id: id) else {
            expect(false, "a crashed chat reloads")
            return
        }
        expect(repaired.messages.last?.state == .failed, "reload repairs a crashed stream")
        reopened.save(repaired)

        let verified = ChatHistoryStore(directory: directory).session(id: id)
        expect(
            verified?.messages.last?.state == .failed,
            "saving a repaired chat persists the repair")
        expect(
            verified?.messages.last?.searches
                == [ChatSearch(query: "news", isComplete: true, textOffset: 1, sequence: 0)],
            "a repaired tail keeps its searches")
    }

    static func retentionPrunesByAgeAndCascades() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ai-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatHistoryStore(directory: directory)

        let now = Date(timeIntervalSince1970: 1_000_000)
        let picture = AIImage(data: Data(repeating: 7, count: 64), mimeType: "image/png")
        func save(id: UUID, at moment: Date, images: [AIImage] = []) {
            var session = ChatSession(id: id, createdAt: moment)
            session.append(
                ChatMessage(role: .user, text: "question", sentAt: moment, images: images))
            session.append(ChatMessage(role: .assistant, text: "answer", sentAt: moment))
            store.save(session)
        }

        let stale = UUID()
        let fresh = UUID()
        save(id: stale, at: now.addingTimeInterval(-40 * 86_400), images: [picture])
        save(id: fresh, at: now.addingTimeInterval(-2 * 86_400))
        expect(store.conversations.count == 2, "both conversations are stored to begin with")

        let cutoff = AIRetention.month.cutoff(from: now)
        expect(cutoff != nil, "a bounded retention has a cutoff")
        let removed = store.prune(before: cutoff!)

        expect(removed == 1, "only the conversation past the cutoff is pruned, got \(removed)")
        expect(
            store.conversations.map(\.id) == [fresh],
            "the resident summaries drop the pruned conversation")
        expect(store.session(id: stale) == nil, "pruning cascades to the pruned messages")
        expect(store.session(id: fresh)?.messages.count == 2, "a newer conversation is untouched")

        // The cascade has to reach the child tables, or blobs outlive the chat that carried them.
        let database = directory.appendingPathComponent("ai-chats.sqlite3")
        expect(
            count(database, "SELECT COUNT(*) FROM messages") == 2,
            "only the surviving conversation's messages remain")
        expect(
            count(database, "SELECT COUNT(*) FROM message_images") == 0,
            "pruning cascades to message_images, so no picture is orphaned")

        expect(store.prune(before: cutoff!) == 0, "a second prune finds nothing left to remove")
        expect(
            AIRetention.forever.cutoff(from: now) == nil,
            "Forever names no cutoff, so nothing is ever pruned")
    }

    static func count(_ database: URL, _ sql: String) -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func tamper(_ database: URL, _ sql: String) -> Bool {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else { return false }
        defer { sqlite3_close(connection) }
        return sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK
    }

    static func temporaryStore(_ name: String) -> (ChatHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ai-\(name)-\(UUID().uuidString)", isDirectory: true)
        return (ChatHistoryStore(directory: directory), directory)
    }

    static func saved(_ store: ChatHistoryStore, _ text: String, at moment: Date) -> UUID {
        var session = ChatSession(createdAt: moment)
        session.append(ChatMessage(role: .user, text: text, sentAt: moment))
        session.append(ChatMessage(role: .assistant, text: "answer", sentAt: moment))
        store.save(session)
        return session.id
    }

    /// A rename or a pin is the reader's; neither a later save nor a retention sweep may undo it.
    static func renamesAndPinsSurviveSavesAndSpareRetention() {
        let (store, directory) = temporaryStore("meta")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = saved(store, "an old question", at: now.addingTimeInterval(-90 * 86_400))
        let pinned = saved(store, "a keeper", at: now.addingTimeInterval(-90 * 86_400))
        let fresh = saved(store, "a fresh question", at: now)

        store.rename(id: fresh, to: "  Trip planning  ")
        store.setPinned(true, id: pinned)
        expect(
            store.conversation(id: fresh)?.displayTitle == "Trip planning",
            "a rename is trimmed and shown in place of the first question")
        expect(store.search("trip").first?.id == fresh, "search matches the renamed title")

        var continued = store.session(id: fresh)!
        continued.append(ChatMessage(role: .user, text: "and hotels?", sentAt: now))
        store.save(continued)
        expect(
            store.conversation(id: fresh)?.displayTitle == "Trip planning",
            "saving a later turn keeps the rename")

        let reopened = ChatHistoryStore(directory: directory)
        reopened.load()
        expect(
            reopened.conversation(id: fresh)?.customTitle == "Trip planning",
            "a rename survives reopening")
        expect(reopened.conversation(id: pinned)?.isPinned == true, "a pin survives reopening")

        reopened.rename(id: fresh, to: "   ")
        expect(
            reopened.conversation(id: fresh)?.displayTitle == "a fresh question",
            "a blank rename hands the title back to the first question")

        let cutoff = AIRetention.month.cutoff(from: now)!
        expect(reopened.prune(before: cutoff) == 1, "retention removes only the unpinned old chat")
        expect(reopened.conversation(id: old) == nil, "the old chat is gone")
        expect(reopened.session(id: pinned) != nil, "a pinned chat outlives retention")

        reopened.clearAll()
        expect(
            reopened.conversations.map(\.id) == [pinned],
            "Delete All keeps the pinned chat and nothing else")
        expect(
            count(
                directory.appendingPathComponent("ai-chats.sqlite3"),
                "SELECT COUNT(*) FROM conversation_details") == 1,
            "a deleted chat's rename cascades away with it")
    }

    static func titlesAreCleanedAndNeverBeatARename() {
        expect(
            ChatTitle.sanitize("Title: \"Weekend Hiking Trip Plan.\"\nmore")
                == "Weekend Hiking Trip Plan",
            "a title loses its label, quotes, full stop and any second line")
        expect(ChatTitle.sanitize("## Trip plan") == "Trip plan", "a heading marker is not the title")
        expect(ChatTitle.sanitize("  \n ") == nil, "an empty answer names nothing")
        var session = ChatSession()
        expect(ChatTitle.description(of: session) == nil, "an empty chat has nothing to name")
        session.append(ChatMessage(role: .user, text: "Is 1001 prime?"))
        expect(
            ChatTitle.description(of: session) == "User: Is 1001 prime?",
            "a chat is named from its question alone while the answer is still coming")
        session.append(ChatMessage(role: .assistant, text: "No: 7 × 11 × 13."))
        expect(
            ChatTitle.description(of: session) == "User: Is 1001 prime?\nAssistant: No: 7 × 11 × 13.",
            "a title is asked for from the first question and answer")

        let (store, directory) = temporaryStore("titles")
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save(session)
        store.setGeneratedTitle("Prime factors of 1001", id: session.id)
        expect(
            store.conversation(id: session.id)?.displayTitle == "Prime factors of 1001",
            "a generated title replaces the first question's")
        store.save(session)
        let reopened = ChatHistoryStore(directory: directory)
        reopened.load()
        expect(
            reopened.conversation(id: session.id)?.generatedTitle == "Prime factors of 1001",
            "a generated title survives a later save and reopening")
        reopened.rename(id: session.id, to: "Maths")
        expect(reopened.conversation(id: session.id)?.displayTitle == "Maths", "a rename still wins")
    }
}

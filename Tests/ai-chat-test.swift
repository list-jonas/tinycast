import Foundation
import SQLite3

@main
@MainActor
struct AIChatTests {
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

    static func main() async {
        leavingAConversationDropsItsStagedImages()
        await arrivalOrderSurvivesTheReplyAndReload()
        await theToolLoopRunsUntilTheModelStopsAsking()
        await theToolLoopRefusesToRunForever()
        await anUnlimitedToolLoopRunsPastEveryStep()
        await anUnlimitedToolLoopStopsWhenItsHistoryIsFull()
        await toolOutputIsBoundedBeforeItIsBilled()
        transcriptsExportAndDropOnlyATrailingReply()
        await regenerateAsksTheSameQuestionAgain()
        await aConversationIsLiveOnOneSurfaceAtATime()
        await everyStateReportsAFinishedReply()
        await reasoningFoldsIntoTheReplyAndIsNeverResent()
        chatsKeepTheirOwnModel()
        toolScopeSwitchesServersPerChat()
        await usageIsKeptWithTheReplyThatReportedIt()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// Created live, stored and reloaded: the order has to come through all three.
    static func arrivalOrderSurvivesTheReplyAndReload() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ai-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let chat = AIChatState(history: ChatHistoryStore(directory: directory))
        let provider = ScriptedProvider(rounds: [
            [
                .toolCall(id: "a", origin: "Files", title: "read"),
                .toolResult(id: "a", isError: false),
                .searching("news"),
                .searched("news"),
                .toolCall(id: "b", origin: "Files", title: "list"),
                .toolResult(id: "b", isError: false),
                .text("Done."),
                .finished
            ]
        ])
        expect(chat.send("go", using: provider), "the turn starts")
        var waited = 0
        while chat.isStreaming, waited < 400 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        let expected = ["tools a", "search news", "tools b", "text Done."]
        expect(
            shape(chat.session.messages.last?.segments) == expected,
            "a search between two calls parts them, live, before any text has arrived")

        let database = directory.appendingPathComponent("ai-chats.sqlite3")
        let reloaded = ChatHistoryStore(directory: directory).session(id: chat.session.id)
        expect(
            shape(reloaded?.messages.last?.segments) == expected,
            "and still parts them once the chat is reopened from history")
        expect(
            count(database, "SELECT position FROM message_searches") == 1,
            "a search's position is its place among the reply's searches and calls")

        expect(
            tamper(
                database,
                """
                UPDATE message_searches SET position = 0;
                UPDATE message_tools SET position = 1 WHERE call_id = 'b';
                """),
            "the harness can store positions the way they were stored before")
        let older = ChatHistoryStore(directory: directory).session(id: chat.session.id)
        expect(
            shape(older?.messages.last?.segments) == ["search news", "tools a,b", "text Done."],
            "a chat stored with each table's own positions loads, a tie going to the search")
    }

    static func shape(_ segments: [ChatSegment]?) -> [String] {
        (segments ?? []).map {
            switch $0 {
            case .text(let text): "text \(text)"
            case .search(let search): "search \(search.query ?? "")"
            case .tools(let uses): "tools \(uses.map(\.callID).joined(separator: ","))"
            case .reasoning(let block): "reasoning \(block.text)"
            }
        }
    }

    static func theToolLoopRunsUntilTheModelStopsAsking() async {
        let base = ScriptedProvider(rounds: [
            [.toolCallRequested(AIToolCall(id: "c1", name: "fs__read", arguments: "{}"))],
            [.text("done"), .finished]
        ])
        let invoker = RecordingInvoker(result: "file contents")
        let events = await collect(loop(base, invoker))

        expect(base.requests.count == 2, "the loop re-streams the turn once per round of calls")
        expect(
            base.requests.first?.tools.map(\.name) == ["fs__read"],
            "and arms every round with the tools it wraps, which the turn itself never carried")
        expect(invoker.calls.map(\.name) == ["fs__read"], "and runs exactly what was asked for")
        expect(
            events.contains(.toolCall(id: "c1", origin: "Files", title: "read")),
            "the transcript is told which tool ran, in words a row can show")
        expect(
            events.contains(.toolResult(id: "c1", isError: false)),
            "and told when it came back")
        expect(
            !events.contains(where: {
                if case .toolCallRequested = $0 { return true }; return false
            }),
            "the transport's own request event never reaches the transcript")
        expect(events.last == .finished, "the turn ends once, when the model stops asking")

        let second = base.requests[1]
        expect(
            second.messages.last?.toolResult?.content == "file contents",
            "the result is fed back as the tool turn the next round reads")
        expect(
            second.messages.dropLast().last?.toolCalls.first?.id == "c1",
            "paired with the assistant turn that asked for it, which no provider accepts orphaned")
    }

    /// A model that only ever calls has stopped answering, and the turn has to end saying so.
    static func theToolLoopRefusesToRunForever() async {
        let round: [AIStreamEvent] = [
            .toolCallRequested(AIToolCall(id: "c", name: "fs__read", arguments: "{}"))
        ]
        let base = ScriptedProvider(rounds: Array(repeating: round, count: 40))
        let invoker = RecordingInvoker(result: "again")
        var failure: String?
        do {
            for try await _ in loop(base, invoker, maxRounds: 3).stream(Self.turn) {}
        } catch {
            failure = error.localizedDescription
        }
        expect(
            base.requests.count == 3,
            "the loop stops at the cap it was given rather than billing another round")
        expect(
            failure?.contains("3 rounds") == true,
            "and the turn fails with a sentence naming the cap it stopped at")
    }

    /// Unlimited has no cap to hit, so only the model's own last answer ends the turn.
    static func anUnlimitedToolLoopRunsPastEveryStep() async {
        let round: [AIStreamEvent] = [
            .toolCallRequested(AIToolCall(id: "c", name: "fs__read", arguments: "{}"))
        ]
        let base = ScriptedProvider(
            rounds: Array(repeating: round, count: 120) + [[.text("done"), .finished]])
        let invoker = RecordingInvoker(result: "again")
        let events = await collect(loop(base, invoker, maxRounds: nil))
        expect(
            base.requests.count == 121,
            "the loop keeps going past 100 rounds when it has no cap")
        expect(events.last == .finished, "and finishes on the model's answer instead of failing")
    }

    /// Every round resends the turn, so Unlimited still ends before its history grows without bound.
    static func anUnlimitedToolLoopStopsWhenItsHistoryIsFull() async {
        let arguments = String(repeating: "x", count: AIToolLoopProvider.maxTurnHistoryBytes / 16)
        let round: [AIStreamEvent] = [
            .toolCallRequested(AIToolCall(id: "c", name: "fs__read", arguments: arguments))
        ]
        let base = ScriptedProvider(rounds: Array(repeating: round, count: 40))
        let invoker = RecordingInvoker(result: "again")
        var failure: String?
        do {
            for try await _ in loop(base, invoker, maxRounds: nil).stream(Self.turn) {}
        } catch {
            failure = error.localizedDescription
        }
        expect(
            base.requests.count == 16,
            "the loop stops on the round whose calls and results fill the turn's history")
        expect(
            failure?.contains("16 rounds") == true,
            "and the turn fails with a sentence naming the rounds it ran")
    }

    static func toolOutputIsBoundedBeforeItIsBilled() async {
        let base = ScriptedProvider(rounds: [
            [.toolCallRequested(AIToolCall(id: "c1", name: "fs__read", arguments: "{}"))],
            [.finished]
        ])
        let invoker = RecordingInvoker(
            result: String(repeating: "x", count: AIToolLoopProvider.maxResultBytes * 2))
        _ = await collect(loop(base, invoker))
        let fed = base.requests[1].messages.last?.toolResult?.content ?? ""
        expect(
            fed.utf8.count <= AIToolLoopProvider.maxResultBytes + 32,
            "a huge result is cut to the per-call ceiling before it enters the context")
        expect(fed.hasSuffix("truncated."), "and says it was cut rather than pretending it was all")
    }

    private static let turn = AIRequest(messages: [AIMessage(role: .user, text: "go")])

    private static func loop(
        _ base: ScriptedProvider, _ invoker: RecordingInvoker, maxRounds: Int? = 10
    ) -> AIToolLoopProvider {
        AIToolLoopProvider(
            base: base,
            tools: [
                AITool(
                    name: "fs__read", description: "", parameters: .object([:]), origin: "Files",
                    title: "read")
            ],
            maxRounds: maxRounds,
            invoke: { call in await invoker.invoke(call) })
    }

    private static func collect(_ provider: AIToolLoopProvider) async -> [AIStreamEvent] {
        var events: [AIStreamEvent] = []
        do {
            for try await event in provider.stream(turn) { events.append(event) }
        } catch {
            events.append(.text("ERROR: \(error.localizedDescription)"))
        }
        return events
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

    /// Leaving a conversation drops its staged images and disowns a decode in flight.
    static func leavingAConversationDropsItsStagedImages() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ai-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ChatHistoryStore(directory: directory)
        let created = Date(timeIntervalSince1970: 3_000)
        let saved = UUID()
        var stored = ChatSession(id: saved, createdAt: created)
        stored.append(ChatMessage(role: .user, text: "Stored", sentAt: created))
        store.save(stored)

        // Distinct bytes per call: `attach` refuses a picture already staged.
        var stamp = 0
        func stage(_ chat: AIChatState) {
            stamp += 1
            chat.attach(
                ChatAttachment(
                    payload: .image(
                        AIImage(data: Data([0x89, UInt8(stamp)]), mimeType: "image/png")),
                    name: "shot-\(stamp).png", preview: nil))
        }

        let opening = AIChatState(history: store)
        stage(opening)
        let beforeOpen = opening.stagingGeneration
        expect(opening.open(id: saved), "a saved conversation opens")
        expect(opening.pendingAttachments.isEmpty, "opening another conversation drops its staged images")
        expect(
            opening.stagingGeneration != beforeOpen,
            "opening another conversation disowns a decode still in flight")

        let reopening = AIChatState(history: store)
        expect(reopening.open(id: saved), "the saved conversation opens once")
        stage(reopening)
        let beforeSame = reopening.stagingGeneration
        expect(reopening.open(id: saved), "reopening the conversation already on screen succeeds")
        expect(
            reopening.pendingAttachments.count == 1 && reopening.stagingGeneration == beforeSame,
            "reopening the conversation already on screen keeps its staged images")

        let deleting = AIChatState(history: store)
        expect(deleting.open(id: saved), "the conversation to delete opens")
        stage(deleting)
        let beforeOther = deleting.stagingGeneration
        deleting.delete(id: UUID())
        expect(
            deleting.pendingAttachments.count == 1 && deleting.stagingGeneration == beforeOther,
            "deleting some other conversation leaves the composer alone")
        deleting.delete(id: saved)
        expect(deleting.pendingAttachments.isEmpty, "deleting the open conversation drops its staged images")

        let clearingAll = AIChatSurfacesState(history: store)
        stage(clearingAll.window)
        clearingAll.deleteAll()
        expect(clearingAll.window.pendingAttachments.isEmpty, "Delete All drops the staged images")

        let starting = AIChatState(history: store)
        stage(starting)
        let beforeNew = starting.stagingGeneration
        starting.startNewChat()
        expect(
            starting.pendingAttachments.isEmpty && starting.stagingGeneration != beforeNew,
            "a new chat drops the staged images")

        let removing = AIChatState(history: store)
        stage(removing)
        stage(removing)
        let beforeRemove = removing.stagingGeneration
        expect(removing.removeLastAttachment(), "backspace takes the last staged image")
        expect(
            removing.stagingGeneration == beforeRemove,
            "taking one staged image back leaves another's decode on its way")
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

    static func transcriptsExportAndDropOnlyATrailingReply() {
        var session = ChatSession()
        expect(!session.dropTrailingReply(), "an empty chat has no reply to drop")
        session.append(
            ChatMessage(
                role: .user, text: "Summarise this",
                documents: [AIDocument(data: Data("x".utf8), mimeType: "text/plain", name: "a.txt")]))
        expect(!session.dropTrailingReply(), "a question with no reply keeps the question")
        session.append(ChatMessage(role: .assistant, text: "It says x."))
        expect(
            session.markdownTranscript(title: "Notes")
                == "# Notes\n\n**You** _(attached: a.txt)_\n\nSummarise this\n\n**AI**\n\nIt says x.",
            "a transcript names each speaker and each attachment")
        expect(
            session.historyBytes == "Summarise this".utf8.count + "It says x.".utf8.count,
            "the context gauge counts every turn that would go out as history")
        let budgeted = ChatSession(messages: [
            ChatMessage(role: .user, text: String(repeating: "a", count: 40)),
            ChatMessage(role: .assistant, text: String(repeating: "b", count: 40)),
            ChatMessage(role: .user, text: "Now?")
        ])
        for budget in [10, 50, 100, 1_000] {
            expect(
                budgeted.sentMessageCount(textBudget: budget)
                    == budgeted.requestMessages(textBudget: budget).count,
                "the gauge's count agrees with the request at a \(budget)-byte budget")
        }
        expect(session.dropTrailingReply(), "a trailing reply can be dropped")
        expect(
            session.messages.map(\.role) == [.user], "dropping the reply leaves the question it answered")
    }

    static func regenerateAsksTheSameQuestionAgain() async {
        let (store, directory) = temporaryStore("regenerate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = AIChatState(history: store)
        let provider = ScriptedProvider(rounds: [
            [.text("First"), .finished], [.text("Second"), .finished]
        ])
        chat.send("Why?", using: provider)
        await settle(chat)
        expect(chat.lastAssistantText == "First", "the first reply arrives")
        expect(chat.regenerate(using: provider), "a finished reply can be regenerated")
        await settle(chat)
        expect(
            chat.session.messages.map(\.text) == ["Why?", "Second"],
            "regenerating replaces the reply rather than adding one")
        expect(
            provider.requests.last?.messages.map(\.text) == ["Why?"],
            "the second request carries the question, not the discarded answer")
        expect(
            store.session(id: chat.session.id)?.messages.map(\.text) == ["Why?", "Second"],
            "the stored transcript holds only the new reply")
    }

    /// Naming hangs off this hook, so a state made after it is set must be told too.
    static func everyStateReportsAFinishedReply() async {
        let (store, directory) = temporaryStore("finished")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = AIChatSurfacesState(history: store)
        var finished: [UUID] = []
        chats.onReplyFinished = { finished.append($0.session.id) }
        chats.window.send("Hi", using: ScriptedProvider(rounds: [[.text("Yo"), .finished]]))
        await settle(chats.window)
        chats.newWindowChat()
        chats.window.send("Again", using: ScriptedProvider(rounds: [[.text("Yo"), .finished]]))
        await settle(chats.window)
        chats.quickAI.send("Quick", using: ScriptedProvider(rounds: [[.text("Yo"), .finished]]))
        await settle(chats.quickAI)
        expect(finished.count == 3, "every surface's replies reach the hook, got \(finished.count)")
        chats.quickAI.send("Fails", using: ScriptedProvider(rounds: [[.text("Half")]]))
        await settle(chats.quickAI)
        expect(finished.count == 3, "a reply that failed is not one to name a chat by")
    }

    /// Two surfaces editing one transcript would each save over the other.
    static func aConversationIsLiveOnOneSurfaceAtATime() async {
        let (store, directory) = temporaryStore("surfaces")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chats = AIChatSurfacesState(history: store)
        let stalled = StalledProvider()

        chats.quickAI.send("Quick question", using: stalled)
        let quick = chats.quickAI
        let quickID = quick.session.id
        expect(chats.continueQuickAIInWindow(), "a Quick AI chat continues in the window")
        expect(chats.window === quick, "the window takes the live state, reply and all")
        expect(chats.quickAI !== quick && chats.quickAI.session.messages.isEmpty, "Quick AI starts over")
        expect(!chats.continueQuickAIInWindow(), "an empty Quick AI has nothing to hand over")
        chats.window.draft = "Half-written"
        expect(!chats.continueQuickAIInWindow(draft: "foo"), "a typed line alone moves no chat")
        expect(
            chats.window.draft == "Half-written\nfoo",
            "and joins the window's draft instead of replacing it")
        chats.window.draft = ""
        expect(!chats.openInQuickAI(id: quickID), "Quick AI will not reopen the window's chat")

        chats.newWindowChat()
        expect(chats.window !== quick, "a new window chat leaves the answering one")
        expect(quick.isStreaming, "leaving a chat mid-reply does not cancel it")
        expect(chats.answeringIDs == [quickID], "the chat still answering is reported as such")
        expect(chats.holder(of: quickID) === quick, "and it is still the one holding the chat")
        expect(chats.openInWindow(id: quickID), "the answering chat can be reopened")
        expect(chats.window === quick, "reopening it returns the same live state")

        stalled.finishAll()
        await settle(quick)
        let settled = saved(store, "older", at: Date(timeIntervalSince1970: 1_000))
        expect(chats.openInQuickAI(id: settled), "a chat nobody holds opens in Quick AI")
        expect(chats.openInWindow(id: settled), "the window can take it from Quick AI")
        expect(chats.quickAI.session.messages.isEmpty, "and Quick AI lets it go")

        store.setPinned(true, id: settled)
        chats.deleteAll()
        expect(chats.window.holds(settled), "Delete All leaves a pinned chat open")
        expect(store.conversation(id: quickID) == nil, "and removes the rest")
    }

    static func reasoningFoldsIntoTheReplyAndIsNeverResent() async {
        let (store, directory) = temporaryStore("reasoning")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = AIChatState(history: store)
        let provider = ScriptedProvider(rounds: [
            [
                .thinking, .reasoning("\n\n"), .reasoning("Let me "), .reasoning("see."),
                .text("Answer"), .reasoning("Checking."), .text(" more"), .finished
            ],
            [.text("Again"), .finished]
        ])
        chat.send("Why?", using: provider)
        await settle(chat)
        let reply = chat.session.messages.last
        expect(
            reply?.reasoning.map(\.text) == ["Let me see.", "Checking."],
            "thinking that resumes after answer text is a second block, got \(reply?.reasoning ?? [])")
        expect(
            reply?.reasoning.map(\.textOffset) == [0, 6],
            "each block is pinned where the answer paused for it")
        expect(reply?.text == "Answer more", "reasoning never leaks into the answer text")
        expect(
            reply?.reasoning.allSatisfy { $0.duration != nil } == true,
            "every block knows how long it thought")
        chat.send("And?", using: provider)
        await settle(chat)
        expect(
            provider.requests.last?.messages.map(\.text) == ["Why?", "Answer more", "And?"],
            "the next turn resends the answer, never the thinking")
        let reloaded = ChatHistoryStore(directory: directory).session(id: chat.session.id)
        expect(
            reloaded?.messages[1].reasoning == reply?.reasoning,
            "reasoning survives reopening the chat")
    }

    /// Coming back to a chat has to come back to the model it was talking to.
    static func chatsKeepTheirOwnModel() {
        let (store, directory) = temporaryStore("model")
        defer { try? FileManager.default.removeItem(at: directory) }
        let opus = AIModelSelection.claude(model: "opus", effort: "high")
        let chat = AIChatState(history: store)
        chat.setModel(opus)
        expect(chat.session.model == opus, "a new chat holds its pick before its first message")
        chat.send("Hi", using: ScriptedProvider(rounds: []), model: opus)
        expect(
            ChatHistoryStore(directory: directory).session(id: chat.session.id)?.model == opus,
            "the first save records the chat's model")
        let sonnet = AIModelSelection.claude(model: "sonnet", effort: nil)
        chat.setModel(sonnet)
        let reopened = AIChatState(history: ChatHistoryStore(directory: directory))
        expect(reopened.open(id: chat.session.id), "the chat reopens")
        expect(reopened.session.model == sonnet, "a later pick is what the chat reopens on")
    }

    static func toolScopeSwitchesServersPerChat() {
        var scope = ChatToolScope()
        expect(scope.allows("files"), "a new chat may call every connected server")
        scope.toggle("files")
        expect(!scope.allows("files") && scope.allows("web"), "one server switches off alone")
        scope.toggle("files")
        scope.isEnabled = false
        expect(!scope.allows("web"), "switching tools off stops every server")
    }

    static func usageIsKeptWithTheReplyThatReportedIt() async {
        let (store, directory) = temporaryStore("usage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reported = AIUsage(
            inputTokens: 10, outputTokens: 59, cachedInputTokens: 6_401, reasoningTokens: 51,
            contextWindow: 200_000, costUSD: 0.0009)
        let chat = AIChatState(history: store)
        chat.send("Hi", using: ScriptedProvider(rounds: [[.text("Yo"), .usage(reported), .finished]]))
        await settle(chat)
        expect(chat.usage == reported, "the reply carries what its route reported")
        expect(reported.contextTokens == 6_470, "the context counts cached prompt tokens too")
        let reopened = AIChatState(history: ChatHistoryStore(directory: directory))
        expect(reopened.open(id: chat.session.id), "the chat reopens")
        expect(reopened.usage == reported, "a reopened chat still knows its last turn's tokens")
    }

    /// Replies stream on a task; a few turns of the main actor let the scripted events land.
    static func settle(_ chat: AIChatState) async {
        for _ in 0..<50 where chat.isStreaming {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Holds every reply open until told to finish, so a test can switch surfaces mid-answer.
final class StalledProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AIProviderStream.Continuation] = []

    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }

    func finishAll() {
        for continuation in lock.withLock({ continuations }) {
            continuation.yield(.text("done"))
            continuation.yield(.finished)
            continuation.finish()
        }
    }
}

/// A base route that replays one scripted round per request, so the loop's driving is what is tested.
final class ScriptedProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [[AIStreamEvent]]
    private var seen: [AIRequest] = []

    init(rounds: [[AIStreamEvent]]) {
        self.rounds = rounds
    }

    var requests: [AIRequest] {
        lock.withLock { seen }
    }

    func stream(_ request: AIRequest) -> AIProviderStream {
        let events: [AIStreamEvent] = lock.withLock {
            seen.append(request)
            return rounds.isEmpty ? [.finished] : rounds.removeFirst()
        }
        return AIProviderStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Stands in for the MCP coordinator: it records what it was asked and answers the same way.
final class RecordingInvoker: @unchecked Sendable {
    private let lock = NSLock()
    private let result: String
    private var received: [AIToolCall] = []

    init(result: String) {
        self.result = result
    }

    var calls: [AIToolCall] {
        lock.withLock { received }
    }

    func invoke(_ call: AIToolCall) async -> AIToolResult {
        lock.withLock { received.append(call) }
        return AIToolResult(callID: call.id, content: result, isError: false)
    }
}

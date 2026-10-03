import Foundation

@main
@MainActor
struct AIStreamTests {
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
        sseFramesSurviveSplits()
        openAIAndAnthropicStreamsDecode()
        capturedStreamsDecodeHoweverTheyArrive()
        thinkTagStreamsDecodeHoweverTheyArrive()
        brokenStreamsFailLoudly()
        requestBodiesCarryDocuments()
        codexProtocolFramesRoundTrip()
        installedCLIStreamsDecode()
        toolCatalogsAndTurnsEncodePerProvider()
        toolArgumentsSurviveArrivingInFragments()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// A wrong document shape must fail here rather than mid-conversation.
    static func requestBodiesCarryDocuments() {
        let pdf = AIDocument(
            data: Data("%PDF-1.4".utf8), mimeType: "application/pdf", name: "report.pdf")
        let image = AIImage(data: Data([0x89, 0x50]), mimeType: "image/png")
        let turn = AIRequest(
            messages: [
                AIMessage(role: .user, text: "summarise", images: [image], documents: [pdf])
            ])

        let anthropic = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
                model: "claude"))
        let blocks =
            (anthropic["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]] ?? []
        expect(
            blocks.map { $0["type"] as? String } == ["image", "document", "text"],
            "Anthropic takes image then document, with the text block last")
        let source =
            blocks.first { $0["type"] as? String == "document" }?["source"]
            as? [String: Any]
        expect(
            source?["type"] as? String == "base64"
                && source?["media_type"] as? String == "application/pdf",
            "as a base64 document source naming its media type")
        expect(
            (source?["data"] as? String)?.contains("\n") == false,
            "whose base64 carries no newlines")

        let openAI = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!,
                model: "gpt"))
        let parts =
            (openAI["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]] ?? []
        expect(
            parts.map { $0["type"] as? String } == ["text", "image_url", "file"],
            "OpenAI keeps its text part first and appends the file part")
        let file = parts.first { $0["type"] as? String == "file" }?["file"] as? [String: Any]
        expect(
            file?["filename"] as? String == "report.pdf",
            "the file part names the document")
        expect(
            (file?["file_data"] as? String)?.hasPrefix("data:application/pdf;base64,") == true,
            "and carries it as a data URL")

        // A turn that is only a document must not collapse to the plain-string fast path.
        let documentOnly = AIRequestBody.make(
            AIRequest(messages: [AIMessage(role: .user, text: "", documents: [pdf])]),
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!,
                model: "gpt"))
        expect(
            ((documentOnly["messages"] as? [[String: Any]])?.first?["content"]
                as? [[String: Any]])?.count == 1,
            "a document-only turn still sends, as content parts")
    }

    /// Both providers stream a call's arguments in pieces; a half-parsed call would be uncallable.
    static func toolArgumentsSurviveArrivingInFragments() {
        var openAI = AIStreamDecoder(shape: .openAICompatible)
        let openAIData = Data(
            """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",\
            "function":{"name":"fs__read","arguments":"{\\"pa"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"/tmp\\"}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """.utf8)
        var events = (try? openAI.feed(openAIData)) ?? []
        events += (try? openAI.finish()) ?? []
        expect(
            events.contains(
                .toolCallRequested(
                    AIToolCall(id: "call_1", name: "fs__read", arguments: #"{"path":"/tmp"}"#))),
            "OpenAI fragments reassemble into one whole call before it leaves the decoder")
        expect(events.last == .finished, "and the stream still terminates")

        var anthropic = AIStreamDecoder(shape: .anthropic)
        let anthropicData = Data(
            """
            data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"fs__read"}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path"}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\":\\"/tmp\\"}"}}

            data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}

            """.utf8)
        var anthropicEvents = (try? anthropic.feed(anthropicData)) ?? []
        anthropicEvents += (try? anthropic.finish()) ?? []
        expect(
            anthropicEvents.contains(
                .toolCallRequested(
                    AIToolCall(id: "toolu_1", name: "fs__read", arguments: #"{"path":"/tmp"}"#))),
            "an Anthropic tool_use block reassembles the same way")
        expect(
            !anthropicEvents.contains(.finished),
            "a tool turn ends without message_stop, so the loop decides whether the turn is over")

        var plain = AIStreamDecoder(shape: .openAICompatible)
        let none = (try? plain.feed(Data("data: [DONE]\n\n".utf8))) ?? []
        expect(
            none == [.finished],
            "a turn that called nothing emits no tool event at all")
    }

    /// Every provider 400s on a call without its result, or a result without its call.
    static func toolCatalogsAndTurnsEncodePerProvider() {
        let tool = AITool(
            name: "fs__read", description: "Reads a file.",
            parameters: .object(["type": .string("object")]), origin: "Files", title: "read")
        let call = AIToolCall(id: "c1", name: "fs__read", arguments: #"{"path":"/tmp"}"#)
        let turn = AIRequest(
            messages: [
                AIMessage(role: .user, text: "read it"),
                AIMessage(role: .assistant, text: "", toolCalls: [call]),
                AIMessage(
                    role: .tool, text: "",
                    toolResult: AIToolResult(callID: "c1", content: "hi", isError: false)),
                AIMessage(
                    role: .tool, text: "",
                    toolResult: AIToolResult(callID: "c2", content: "no", isError: true))
            ],
            tools: [tool])

        let openAI = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!,
                model: "gpt-5"))
        let catalog = (openAI["tools"] as? [[String: Any]])?.first
        expect(
            catalog?["type"] as? String == "function",
            "OpenAI takes a tool wrapped as a function")
        expect(
            (catalog?["function"] as? [String: Any])?["parameters"] is [String: Any],
            "and the server's own schema is handed through as the parameters, unrewritten")
        let openAIMessages = openAI["messages"] as? [[String: Any]] ?? []
        let assistant = openAIMessages.first { $0["tool_calls"] != nil }
        expect(
            ((assistant?["tool_calls"] as? [[String: Any]])?.first?["id"] as? String) == "c1",
            "the assistant turn keeps the id its result has to quote")
        let results = openAIMessages.filter { $0["role"] as? String == "tool" }
        expect(results.count == 2, "each result is its own tool turn")
        expect(
            results.first?["tool_call_id"] as? String == "c1",
            "addressed by the call it answers")

        let anthropic = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
                model: "claude"))
        let anthropicTool = (anthropic["tools"] as? [[String: Any]])?.first
        expect(
            anthropicTool?["input_schema"] != nil && anthropicTool?["type"] == nil,
            "Anthropic names the same schema input_schema and takes no wrapper")
        let anthropicMessages = anthropic["messages"] as? [[String: Any]] ?? []
        let use =
            (anthropicMessages.first { $0["role"] as? String == "assistant" }?["content"]
            as? [[String: Any]])?.first
        expect(use?["type"] as? String == "tool_use", "a call is a content block, not a field")
        expect(
            (use?["input"] as? [String: Any])?["path"] as? String == "/tmp",
            "and its arguments are parsed back into the object Anthropic expects")
        let resultBlocks =
            anthropicMessages.last?["content"] as? [[String: Any]] ?? []
        expect(
            anthropicMessages.last?["role"] as? String == "user",
            "Anthropic takes results as a user turn")
        expect(
            resultBlocks.count == 2,
            "and a run of them arrives as one turn, because two would be rejected")
        expect(
            resultBlocks.last?["is_error"] as? Bool == true,
            "a tool's own failure stays marked so the model can work around it")

        let plain = AIRequestBody.make(
            AIRequest(messages: [AIMessage(role: .user, text: "hi")]),
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!,
                model: "gpt-5"))
        expect(plain["tools"] == nil, "a turn with no tools sends no tools key at all")

        let router = AIRequestBody.make(
            AIRequest(messages: [AIMessage(role: .user, text: "hi")]),
            configuration: AIHTTPConfiguration(
                provider: .openRouter, baseURL: URL(string: "https://openrouter.ai/api/v1")!,
                model: "openai/gpt-5", effort: "low"))
        expect(
            (router["reasoning"] as? [String: String])?["effort"] == "low",
            "OpenRouter receives the reasoning effort its catalog offered")
    }

    static func sseFramesSurviveSplits() {
        var parser = SSEParser()
        expect(parser.feed(Data("data: hel".utf8)).isEmpty, "a partial SSE frame waits")
        expect(
            parser.feed(Data("lo\n\ndata: world\r\n\r\n".utf8)) == ["hello", "world"],
            "split LF and CRLF frames are reassembled")
        expect(
            parser.feed(Data(": keepalive\n\ndata: final".utf8)).isEmpty,
            "comments are ignored and a final unterminated frame waits")
        expect(parser.finish() == ["final"], "finish flushes the final frame")
    }

    static func openAIAndAnthropicStreamsDecode() {
        var openAI = AIStreamDecoder(shape: .openAICompatible)
        let openAIData = Data(
            """
            data: {"choices":[{"delta":{"reasoning":"working"}}]}

            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}

            data: [DONE]

            """.utf8)
        var events = (try? openAI.feed(openAIData)) ?? []
        events += (try? openAI.finish()) ?? []
        expect(events.contains(.thinking), "reasoning is surfaced as state, not answer text")
        expect(events.contains(.reasoning("working")), "and its text reaches the reasoning fold")
        expect(events.contains(.text("Hello")), "OpenAI-compatible text is decoded")
        expect(
            events.contains(.usage(AIUsage(inputTokens: 3, outputTokens: 2))),
            "OpenAI-compatible usage is decoded")
        expect(events.last == .finished, "the OpenAI done marker terminates the stream")

        var anthropic = AIStreamDecoder(shape: .anthropic)
        let anthropicData = Data(
            """
            data: {"type":"message_start","message":{"usage":{"input_tokens":4}}}

            data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Hmm"}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

            data: {"type":"message_delta","usage":{"output_tokens":1}}

            data: {"type":"message_stop"}

            """.utf8)
        var anthropicEvents = (try? anthropic.feed(anthropicData)) ?? []
        anthropicEvents += (try? anthropic.finish()) ?? []
        expect(anthropicEvents.contains(.text("Hi")), "Anthropic text is decoded")
        expect(
            anthropicEvents.contains(.reasoning("Hmm")) && !anthropicEvents.contains(.text("Hmm")),
            "Anthropic thinking is reasoning, never answer text")
        expect(
            anthropicEvents.contains(.usage(AIUsage(inputTokens: 4, outputTokens: 1))),
            "Anthropic usage accumulates across events")
        expect(anthropicEvents.last == .finished, "Anthropic message_stop terminates the stream")
    }

    /// Real OpenRouter captures, with the reasoning ones proving thought never leaks into text.
    static func capturedStreamsDecodeHoweverTheyArrive() {
        let captures: [(file: String, text: String?, reasons: Bool)] = [
            ("openrouter-plain", "1, 2, 3.", false),
            ("openrouter-gemma", nil, false),
            ("openrouter-nemotron-reasoning", nil, true),
            ("openrouter-cohere-reasoning", nil, true)
        ]
        for capture in captures {
            guard let data = FileManager.default.contents(atPath: "Tests/ai-fixtures/\(capture.file).txt")
            else {
                expect(false, "\(capture.file) fixture is readable")
                continue
            }
            let whole = decodeAll(data, slice: data.count)
            let sliced = decodeAll(data, slice: 7)
            expect(whole == sliced, "\(capture.file) decodes the same in 7-byte slices")
            let text = whole.compactMap { event -> String? in
                if case .text(let text) = event { return text }
                return nil
            }.joined()
            if let expected = capture.text {
                expect(text == expected, "\(capture.file) yields exactly its answer text")
            } else {
                expect(!text.isEmpty, "\(capture.file) yields answer text")
            }
            expect(
                whole.contains(.thinking) == capture.reasons,
                "\(capture.file) surfaces thinking only when the model reasoned")
            expect(whole.last == .finished, "\(capture.file) ends on the done marker")
            expect(
                whole.contains {
                    if case .usage(let usage) = $0 { return usage.totalTokens != nil } else { return false }
                },
                "\(capture.file) reports final usage")
        }
    }

    static func thinkTagStreamsDecodeHoweverTheyArrive() {
        guard let data = FileManager.default.contents(atPath: "Tests/ai-fixtures/openai-think-tags.txt")
        else {
            expect(false, "think tags: fixture is readable")
            return
        }
        let whole = decodeAll(data, slice: data.count)
        expect(whole == decodeAll(data, slice: 7), "think tags: fixture survives 7-byte slices")
        expect(reasoningText(whole) == "Plan carefully.", "think tags: fixture reasoning is exact")
        expect(answerText(whole) == "The answer.", "think tags: fixture answer is exact")
        expect(whole.contains(.thinking), "think tags: fixture surfaces thinking")
        expect(
            whole.suffix(2) == [.usage(AIUsage(inputTokens: 5, outputTokens: 9)), .finished],
            "think tags: fixture keeps usage before completion")

        let content = Array("<think>reason</think>\n\nanswer")
        for first in 0...content.count {
            for second in first...content.count {
                let fragments = [
                    String(content[..<first]), String(content[first..<second]),
                    String(content[second...])
                ]
                let events = decodeContent(fragments)
                expect(
                    reasoningText(events) == "reason" && answerText(events) == "answer",
                    "think tags: content splits \(first),\(second) preserve reasoning and answer")
            }
        }
        let characters = decodeContent(content.map(String.init))
        expect(
            reasoningText(characters) == "reason" && answerText(characters) == "answer",
            "think tags: one character per delta preserves reasoning and answer")
        let spaced = decodeContent([" \n", "<think> ", "\n", "reason \n</thi", "nk>\n", "\t", "answer", " \n"]
        )
        expect(
            reasoningText(spaced) == " \nreason \n" && answerText(spaced) == "answer \n",
            "think tags: only leading tag space and the answer separator are removed")
        expect(
            decodeContent(["<think>r</think>answer"])
                == [.thinking, .reasoning("r"), .text("answer"), .finished],
            "think tags: a single delta emits reasoning before answer text")
        for literal in [
            "<div>x</div>", "<thinking>…", "\n\nHello", "Hello <think>x</think> world",
            "Hello<think>x</think> world", "</think>answer"
        ] {
            let events = decodeContent(literal.map(String.init))
            expect(
                answerText(events) == literal && !events.contains(.thinking),
                "think tags: literal content stays verbatim: \(literal.debugDescription)")
        }
        for content in ["<think></think>", "<think> \n\t</think>"] {
            expect(
                decodeContent(content.map(String.init)) == [.finished],
                "think tags: empty or whitespace-only reasoning emits nothing")
        }
        let secondBlock = decodeContent(["<think>r</think>", "answer <think>literal</think> world"])
        expect(
            answerText(secondBlock) == "answer <think>literal</think> world",
            "think tags: recognition never resumes after the first block")
        for done in [true, false] {
            let unclosed = decodeContent(["<think>reason</thi"], done: done)
            expect(
                reasoningText(unclosed) == "reason</thi" && answerText(unclosed).isEmpty,
                "think tags: unclosed reasoning flushes at \(done ? "DONE" : "EOF")")
            expect(
                answerText(decodeContent(["<thi"], done: done)) == "<thi",
                "think tags: undecided content flushes at \(done ? "DONE" : "EOF")")
        }
        var decoder = AIStreamDecoder(shape: .openAICompatible)
        _ = try? decoder.feed(contentFrame("<thi"))
        expect((try? decoder.finish()) == [.text("<thi")], "think tags: EOF flushes the held prefix")
        expect((try? decoder.finish()) == [], "think tags: EOF never flushes twice")
        var terminated = AIStreamDecoder(shape: .openAICompatible)
        _ = try? terminated.feed(contentFrame("<think>r</thi"))
        expect(
            (try? terminated.feed(Data("data: [DONE]\n\n".utf8)))
                == [.thinking, .reasoning("</thi"), .finished],
            "think tags: DONE flushes reasoning before completion")
        expect((try? terminated.finish()) == [], "think tags: EOF after DONE never flushes twice")
        let tools = Data(
            """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read","arguments":"{}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":3}}

            data: [DONE]

            """.utf8)
        let toolEvents = decodeAll(contentFrame("<think>r</think>") + tools, slice: 7)
        expect(
            toolEvents == [
                .thinking, .reasoning("r"),
                .toolCallRequested(AIToolCall(id: "c1", name: "read", arguments: "{}")),
                .usage(AIUsage(inputTokens: 2, outputTokens: 3)), .finished
            ],
            "think tags: reasoning precedes tools without changing tool, usage or completion order")
        let native = Data(
            """
            data: {"choices":[{"delta":{"reasoning_content":"native"}}]}

            data: {"choices":[{"delta":{"content":"answer"}}]}

            data: [DONE]

            """.utf8)
        expect(
            decodeAll(native, slice: 7) == [.thinking, .reasoning("native"), .text("answer"), .finished],
            "think tags: reasoning_content retains its original event sequence")
    }

    private static func contentFrame(_ content: String) -> Data {
        guard let encoded = try? JSONEncoder().encode(content),
            let quoted = String(bytes: encoded, encoding: .utf8)
        else {
            preconditionFailure("A content string must encode as JSON")
        }
        return Data("data: {\"choices\":[{\"delta\":{\"content\":\(quoted)}}]}\n\n".utf8)
    }

    private static func decodeContent(_ fragments: [String], done: Bool = true) -> [AIStreamEvent] {
        var data = fragments.reduce(into: Data()) { $0 += contentFrame($1) }
        if done { data += Data("data: [DONE]\n\n".utf8) }
        return decodeAll(data, slice: max(1, data.count))
    }

    private static func reasoningText(_ events: [AIStreamEvent]) -> String {
        events.compactMap { event -> String? in
            if case .reasoning(let text) = event { return text }
            return nil
        }.joined()
    }

    private static func answerText(_ events: [AIStreamEvent]) -> String {
        events.compactMap { event -> String? in
            if case .text(let text) = event { return text }
            return nil
        }.joined()
    }

    private static func decodeAll(_ data: Data, slice: Int) -> [AIStreamEvent] {
        var decoder = AIStreamDecoder(shape: .openAICompatible)
        var events: [AIStreamEvent] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + slice, data.count)
            events += (try? decoder.feed(data[offset..<end])) ?? []
            offset = end
        }
        events += (try? decoder.finish()) ?? []
        return events
    }

    static func brokenStreamsFailLoudly() {
        var decoder = AIStreamDecoder(shape: .openAICompatible)
        let failure = Data(
            """
            data: {"choices":[{"delta":{"content":"Par"}}]}

            data: {"error":{"message":"Provider returned error","code":502}}

            data: {"choices":[{"delta":{"content":"never"}}]}

            """.utf8)
        var events: [AIStreamEvent] = []
        var thrown: Error?
        do { events = try decoder.feed(failure) } catch { thrown = error }
        expect(
            thrown as? AIProviderError == .responseFailed("Provider returned error"),
            "a mid-stream error payload fails with the provider's message")
        expect(decoder.isTerminal, "a mid-stream error ends the stream")
        expect(events.isEmpty, "nothing after the error is decoded")

        var malformed = AIStreamDecoder(shape: .openAICompatible)
        let garbage = Data("data: {not json\n\n".utf8)
        expect(
            (try? malformed.feed(garbage)) == nil,
            "unparseable JSON is rejected rather than skipped")
        expect(malformed.isTerminal, "a malformed frame ends the stream")

        var anthropic = AIStreamDecoder(shape: .anthropic)
        let rejected = Data(
            "data: {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}\n\n".utf8)
        var anthropicError: Error?
        do { _ = try anthropic.feed(rejected) } catch { anthropicError = error }
        expect(
            anthropicError as? AIProviderError
                == .responseFailed("API key rejected — check it in Settings."),
            "an Anthropic error event names the cause without echoing the key")

        var silent = AIStreamDecoder(shape: .openAICompatible)
        let truncated = Data("data: {\"choices\":[{\"delta\":{\"content\":\"half\"}}]}\n\n".utf8)
        let partial = (try? silent.feed(truncated)) ?? []
        expect(partial == [.text("half")], "text before a cut-off is still delivered")
        expect(!silent.isTerminal, "a stream without a done marker stays open for the caller to fail")
    }

    static func codexProtocolFramesRoundTrip() {
        let request = try? CodexAppServerProtocol.request(
            id: 7, method: "account/read", params: ["refreshToken": false])
        let requestObject = request.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        expect((requestObject?["id"] as? Int) == 7, "Codex requests keep numeric IDs")
        expect(
            requestObject?["method"] as? String == "account/read",
            "Codex requests keep their method")

        let response = Data("{\"id\":7,\"result\":{\"ok\":true}}".utf8)
        if case .response(let id, let result) = CodexAppServerProtocol.parse(response) {
            expect(id == 7, "Codex responses route to the pending request")
            expect(result["ok"]?.boolValue == true, "Codex response values preserve booleans")
        } else {
            expect(false, "a valid Codex response parses")
        }
    }

    static func installedCLIStreamsDecode() {
        let openCodeText = Data(
            #"{"type":"text","sessionID":"ses_1","part":{"text":"Hello"}}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(openCodeText, kind: .openCode)
                == InstalledAIStreamFrame(events: [.text("Hello")], sessionID: "ses_1"),
            "OpenCode text and its cleanup session decode together")
        let openCodeFinish = Data(
            #"{"type":"step_finish","part":{"tokens":{"input":12,"output":4}}}"#.utf8)
        let openCodeFrame = InstalledAIStreamDecoder.decode(openCodeFinish, kind: .openCode)
        expect(
            openCodeFrame.events == [.usage(AIUsage(inputTokens: 12, outputTokens: 4))]
                && openCodeFrame.completed,
            "OpenCode completion reports usage and finishes")

        let claudeText = Data(
            #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hi"}}}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(claudeText, kind: .claude).events == [.text("Hi")],
            "Claude partial text decodes without replaying its full assistant message")
        let claudeFinish = Data(
            #"{"type":"result","is_error":false,"usage":{"input_tokens":8,"output_tokens":3}}"#.utf8)
        let claudeFrame = InstalledAIStreamDecoder.decode(claudeFinish, kind: .claude)
        expect(
            claudeFrame.events == [.usage(AIUsage(inputTokens: 8, outputTokens: 3))]
                && claudeFrame.completed,
            "Claude result usage ends the stream")

        let cursorDelta = Data(
            #"{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"Hi"}]}}"#
                .utf8)
        expect(
            InstalledAIStreamDecoder.decode(cursorDelta, kind: .cursor).events == [.text("Hi")],
            "Cursor live deltas decode as text")
        let cursorFlush = Data(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hi"}]}}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(cursorFlush, kind: .cursor).events.isEmpty,
            "Cursor buffered flushes without timestamp_ms are ignored")
        let cursorDone = Data(#"{"type":"result","subtype":"success","result":"Hi"}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(cursorDone, kind: .cursor).completed,
            "Cursor result ends the stream")
        let cursorSession = Data(
            #"{"type":"system","subtype":"init","session_id":"ses_cursor"}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(cursorSession, kind: .cursor).sessionID == "ses_cursor",
            "Cursor system init carries the session id for cleanup")
        let grokText = Data(
            #"{"type":"stream_event","session_id":"ses_g","event":{"delta":{"type":"text_delta","text":"Yo"}}}"#
                .utf8)
        let grokTextFrame = InstalledAIStreamDecoder.decode(grokText, kind: .grok)
        expect(
            grokTextFrame.events == [.text("Yo")] && grokTextFrame.sessionID == "ses_g",
            "Grok partial text reuses the Claude stream shape and keeps the session id")
        let grokFinish = Data(
            #"{"type":"result","is_error":false,"session_id":"ses_g","usage":{"input_tokens":5,"output_tokens":1}}"#
                .utf8)
        let grokFrame = InstalledAIStreamDecoder.decode(grokFinish, kind: .grok)
        expect(
            grokFrame.events == [.usage(AIUsage(inputTokens: 5, outputTokens: 1))]
                && grokFrame.completed && grokFrame.sessionID == "ses_g",
            "Grok result usage ends the stream and names the session to delete")
        let grokError = Data(
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Not signed in."],"session_id":""}"#
                .utf8)
        let grokErrorFrame = InstalledAIStreamDecoder.decode(grokError, kind: .grok)
        expect(
            grokErrorFrame.error == "Not signed in." && grokErrorFrame.sessionID == nil
                && !grokErrorFrame.completed,
            "Grok execution errors name the cause, not Claude, and ignore an empty session id")
        let grokBare = Data(#"{"type":"result","is_error":true}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(grokBare, kind: .grok).error
                == "Grok could not finish the response.",
            "a Grok error with no cause still names Grok")
    }
}

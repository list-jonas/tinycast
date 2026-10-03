import Foundation

@main
@MainActor
struct ChatModelTests {
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
        sessionSummariesAndRequests()
        requestsKeepOnlyBoundedContext()
        attachmentsStayInsideTheTurnBudget()
        attachedTextInlinesOnlyIntoTheRequest()
        onlyPDFsSurviveAsDocuments()
        inlinedTextIsFencedAndNamed()
        attachmentPolicyClassifiesWhatCanBeAttached()
        markdownParsesStreamingFriendlyBlocks()
        markdownParsesTablesQuotesAndLists()
        markdownKeepsCommonMarkEdges()
        markdownFindsMathButNotPrices()
        markdownDisplayMathIsItsOwnBlock()
        mathParsesTheSupportedSubsetOnly()
        mathStillArrivingIsHeldBackOnlyAtTheEnd()
        segmentsClampSearchOffsets()
        segmentsInterleaveSearchesAndTools()
        consecutiveToolCallsMerge()
        searchesSeparateToolRuns()
        arrivalOrderBreaksOffsetTies()
        textSeparatesToolRuns()
        singleToolCallsStaySingle()
        toolRunsDescribeTheirState()
        choicesComeOutOfTheirFence()
        referencesAreTheLinksAReplyCites()
        findWalksMatchesAndWraps()
        citationsCloseTheSentenceThatCitedThem()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// A reply that searched and called tools has to render them in the order they happened.
    static func segmentsInterleaveSearchesAndTools() {
        let message = ChatMessage(
            role: .assistant, text: "abcdef",
            searches: [ChatSearch(query: "q", isComplete: true, textOffset: 4, sequence: 1)],
            toolUses: [
                ChatToolUse(
                    callID: "1", origin: "Files", title: "read", state: .completed, textOffset: 2,
                    sequence: 0)
            ])
        expect(
            message.segments == [
                .text("ab"),
                .tools([
                    ChatToolUse(
                        callID: "1", origin: "Files", title: "read", state: .completed,
                        textOffset: 2, sequence: 0)
                ]),
                .text("cd"),
                .search(ChatSearch(query: "q", isComplete: true, textOffset: 4, sequence: 1)),
                .text("ef")
            ],
            "segments interleave by offset, whichever kind of interruption came first")
        expect(
            ChatToolUse(
                callID: "1", origin: "Files", title: "read", state: .running, textOffset: 0,
                sequence: 0
            ).label
                == "Calling Files · read",
            "a running call says so, and names the server it is calling")
    }

    static func consecutiveToolCallsMerge() {
        let uses = [
            ChatToolUse(
                callID: "1", origin: "Files", title: "read", state: .completed, textOffset: 2,
                sequence: 0),
            ChatToolUse(
                callID: "2", origin: "Files", title: "list", state: .failed, textOffset: 2,
                sequence: 1),
            ChatToolUse(
                callID: "3", origin: "Files", title: "find", state: .running, textOffset: 2,
                sequence: 2)
        ]
        let message = ChatMessage(role: .assistant, text: "abcd", toolUses: uses)
        expect(
            message.segments == [.text("ab"), .tools(uses), .text("cd")],
            "consecutive calls form one run in call order, regardless of state")
    }

    /// No text has arrived, so every offset is 0 and only the order they came in can place them.
    static func searchesSeparateToolRuns() {
        let first = ChatToolUse(
            callID: "1", origin: "Files", title: "read", state: .completed, textOffset: 0,
            sequence: 0)
        let last = ChatToolUse(
            callID: "2", origin: "Files", title: "list", state: .completed, textOffset: 0,
            sequence: 3)
        let searches = [
            ChatSearch(query: "one", isComplete: true, textOffset: 0, sequence: 1),
            ChatSearch(query: "two", isComplete: true, textOffset: 0, sequence: 2)
        ]
        let message = ChatMessage(
            role: .assistant, text: "", searches: searches, toolUses: [first, last])
        expect(
            message.segments == [
                .tools([first]), .search(searches[0]), .search(searches[1]), .tools([last])
            ],
            "searches stay separate and break tool runs in a reply with no text")
    }

    static func arrivalOrderBreaksOffsetTies() {
        let first = ChatToolUse(
            callID: "1", origin: "Files", title: "read", state: .completed, textOffset: 2,
            sequence: 0)
        let search = ChatSearch(query: "q", isComplete: true, textOffset: 2, sequence: 1)
        let last = ChatToolUse(
            callID: "2", origin: "Files", title: "list", state: .completed, textOffset: 2,
            sequence: 2)
        let message = ChatMessage(
            role: .assistant, text: "abcd", searches: [search], toolUses: [first, last])
        expect(
            message.segments == [
                .text("ab"), .tools([first]), .search(search), .tools([last]), .text("cd")
            ],
            "at one offset a call, a search and a call keep the order they came in")
    }

    static func textSeparatesToolRuns() {
        let first = ChatToolUse(
            callID: "1", origin: "Files", title: "read", state: .completed, textOffset: 0,
            sequence: 0)
        let last = ChatToolUse(
            callID: "2", origin: "Files", title: "list", state: .completed, textOffset: 1,
            sequence: 1)
        let message = ChatMessage(role: .assistant, text: " ", toolUses: [first, last])
        expect(
            message.segments == [.tools([first]), .text(" "), .tools([last])],
            "even whitespace between calls separates their runs")
    }

    static func singleToolCallsStaySingle() {
        let use = ChatToolUse(
            callID: "1", origin: "Files", title: "read", state: .completed, textOffset: 0,
            sequence: 0)
        let message = ChatMessage(role: .assistant, text: "", toolUses: [use])
        expect(message.segments == [.tools([use])], "a lone call remains a run of one")
        expect(
            ChatMessage(role: .assistant, text: "").segments.isEmpty,
            "a reply without calls never creates an empty run")
    }

    static func toolRunsDescribeTheirState() {
        var uses = [
            ChatToolUse(
                callID: "1", origin: "Files", title: "read", state: .running, textOffset: 0,
                sequence: 0),
            ChatToolUse(
                callID: "2", origin: "Files", title: "list", state: .running, textOffset: 0,
                sequence: 1),
            ChatToolUse(
                callID: "3", origin: "Files", title: "find", state: .failed, textOffset: 0,
                sequence: 2)
        ]
        expect(uses.isLive, "any running call keeps the run live")
        expect(uses.runningCall == uses[1], "the latest running call owns the live line")
        expect(uses.failedCount == 1, "failures are counted while other calls are running")
        uses[1].state = .completed
        expect(uses.isLive, "finishing one call cannot settle another that is still running")
        expect(uses.runningCall == uses[0], "the remaining running call owns the live line")
        uses[0].state = .completed
        expect(!uses.isLive && uses.runningCall == nil, "a settled run has no running call")
        expect(uses.completedLabel == "Called 3 tools · 1 failed", "the summary names one failure")
        uses[0].state = .failed
        expect(uses.failedCount == 2, "every failed call is counted")
        expect(uses.completedLabel == "Called 3 tools · 2 failed", "the summary names all failures")
        uses[0].state = .completed
        uses[2].state = .completed
        expect(uses.failedCount == 0, "successful runs have no failures")
        expect(uses.completedLabel == "Called 3 tools", "successful summaries omit failures")
    }

    static func sessionSummariesAndRequests() {
        let now = Date(timeIntervalSince1970: 100)
        var session = ChatSession(createdAt: now)
        session.append(
            ChatMessage(
                role: .user, text: "  Explain   the\nlauncher action layout  ", sentAt: now))
        session.append(
            ChatMessage(role: .assistant, text: "It uses one primary action.", sentAt: now))
        session.append(
            ChatMessage(
                role: .assistant, text: "Provider failed", state: .failed, sentAt: now))

        expect(session.title == "Explain the launcher action layout", "titles collapse whitespace")
        expect(session.preview == "Provider failed", "previews use the latest visible message")
        expect(session.requestMessages().count == 2, "failed replies do not poison the next request")
        expect(session.requestMessages().last?.role == .assistant, "complete replies remain context")
    }

    static func requestsKeepOnlyBoundedContext() {
        let now = Date(timeIntervalSince1970: 100)
        let picture = AIImage(data: Data([1, 2, 3]), mimeType: "image/png")
        var session = ChatSession(createdAt: now)
        session.append(ChatMessage(role: .user, text: "First", sentAt: now, images: [picture]))
        session.append(ChatMessage(role: .assistant, text: "Reply", sentAt: now))
        session.append(ChatMessage(role: .user, text: "Second", sentAt: now, images: [picture]))
        let request = session.requestMessages()
        expect(request.count == 3, "a small chat is sent whole")
        expect(request.first?.images.isEmpty == true, "older turns drop their images")
        expect(request.last?.images == [picture], "the newest user turn keeps its images")

        let big = String(repeating: "a", count: 100_001)
        var bloated = ChatSession(createdAt: now)
        bloated.append(ChatMessage(role: .user, text: big, sentAt: now))
        bloated.append(ChatMessage(role: .assistant, text: "Reply", sentAt: now))
        bloated.append(ChatMessage(role: .user, text: "Second", sentAt: now))
        expect(
            bloated.requestMessages().map(\.text) == ["Second"],
            "a reply never survives without the user turn that prompted it")

        var huge = ChatSession(createdAt: now)
        huge.append(ChatMessage(role: .user, text: big, sentAt: now))
        expect(huge.requestMessages().first?.text == big, "the newest user message is never trimmed")

        var overloaded = ChatSession(createdAt: now)
        overloaded.append(
            ChatMessage(
                role: .user, text: "Look", sentAt: now,
                images: Array(repeating: picture, count: AIAttachmentBudget.maxCount + 3)))
        expect(
            overloaded.requestMessages().last?.images.count == AIAttachmentBudget.maxCount,
            "the newest turn's own pictures are bounded too, whatever staged them")

        let whole = ChatSession.boundedContext(
            [
                AIMessage(role: .user, text: "aaaaa"),
                AIMessage(role: .assistant, text: "bbbbb"),
                AIMessage(role: .user, text: "cc")
            ], textBudget: 10)
        expect(
            whole.map(\.text) == ["aaaaa", "bbbbb", "cc"],
            "a turn that fits the budget survives whole")
        let walked = ChatSession.boundedContext(
            [
                AIMessage(role: .user, text: "aaaaa"),
                AIMessage(role: .assistant, text: "bbbbb"),
                AIMessage(role: .user, text: "cc")
            ], textBudget: 9)
        expect(
            walked.map(\.text) == ["cc"],
            "the budget drops whole turns oldest-first, never half a turn")
    }

    static func attachmentsStayInsideTheTurnBudget() {
        let small = AIImage(data: Data(repeating: 7, count: 1_024), mimeType: "image/png")
        let staged = Array(repeating: small, count: AIAttachmentBudget.maxCount)
        expect(
            !AIAttachmentBudget.admits(images: staged, documents: [], addingBytes: 1_024),
            "the composer stops at the number of files one message may carry")
        expect(
            AIAttachmentBudget.admits(
                images: Array(staged.dropLast()), documents: [], addingBytes: 1_024),
            "one under that count still fits")

        let pdf = AIDocument(
            data: Data(repeating: 3, count: 1_024), mimeType: "application/pdf", name: "a.pdf")
        expect(
            !AIAttachmentBudget.admits(
                images: Array(staged.dropLast()), documents: [pdf], addingBytes: 1_024),
            "the count is images and documents together, not one ceiling each")

        expect(
            AIAttachmentBudget.admits(
                images: [], documents: [], addingBytes: AIAttachmentBudget.maxBytes),
            "one file may spend the whole byte budget")
        expect(
            !AIAttachmentBudget.admits(
                images: [small], documents: [], addingBytes: AIAttachmentBudget.maxBytes),
            "bytes are counted across the turn, not per file")
        expect(
            !AIAttachmentBudget.admits(
                images: [], documents: [pdf], addingBytes: AIAttachmentBudget.maxBytes),
            "and a document's bytes count the same as a picture's")

        let heavy = AIImage(
            data: Data(repeating: 7, count: AIAttachmentBudget.maxBytes), mimeType: "image/png")
        let cappedByCount = AIAttachmentBudget.bounded(staged + [small], [pdf])
        expect(
            cappedByCount.images.count == AIAttachmentBudget.maxCount
                && cappedByCount.documents.isEmpty,
            "the backstop drops what the joint count cannot carry")
        expect(
            AIAttachmentBudget.bounded([small, heavy, small], []).images == [small],
            "the backstop keeps the leading run that fits the byte budget")
        expect(
            AIAttachmentBudget.bounded([heavy], [pdf]).documents.isEmpty,
            "and images fill first, so a picture is never dropped for a document behind it")
    }

    /// A pasted file must not be able to become the conversation's title or its history preview.
    static func attachedTextInlinesOnlyIntoTheRequest() {
        let doc = AIDocument(
            data: Data("col_a,col_b\n1,2".utf8), mimeType: "text/csv", name: "rows.csv")
        var session = ChatSession()
        session.append(ChatMessage(role: .user, text: "what is this?", documents: [doc]))

        expect(
            session.messages.last?.text == "what is this?",
            "the transcript keeps what the reader actually typed")
        let sent = session.requestMessages().last?.text ?? ""
        expect(sent.contains("Attached file: rows.csv"), "the request names the file")
        expect(sent.contains("col_a,col_b"), "and carries its contents")
        expect(sent.hasSuffix("what is this?"), "with the typed question after the attachment")
    }

    /// A text file is inlined, so only a PDF may reach a transport as a document block.
    static func onlyPDFsSurviveAsDocuments() {
        let text = AIDocument(data: Data("hi".utf8), mimeType: "text/plain", name: "a.txt")
        let pdf = AIDocument(data: Data("%PDF".utf8), mimeType: "application/pdf", name: "b.pdf")
        var session = ChatSession()
        session.append(ChatMessage(role: .user, text: "read these", documents: [text, pdf]))
        let sent = session.requestMessages().last
        expect(sent?.documents == [pdf], "the text file inlines and the PDF stays a document")
    }

    /// A fence must out-length any run inside the file, or a Markdown file escapes its own block.
    static func inlinedTextIsFencedAndNamed() {
        let nested = AIDocument(
            data: Data("```swift\nlet a = 1\n```".utf8), mimeType: "text/markdown",
            name: "notes.md")
        let out = AIAttachmentPolicy.prompt(text: "", documents: [nested])
        expect(out.contains("````md"), "the fence out-lengths the longest run inside")
        expect(
            AIAttachmentPolicy.sanitized(name: "a\nAttached file: passwd").count <= 64,
            "a newline in a name cannot forge a second header")
        expect(
            !AIAttachmentPolicy.sanitized(name: "a\nb").contains("\n"),
            "newlines are stripped from a staged name")
    }

    static func attachmentPolicyClassifiesWhatCanBeAttached() {
        expect(AIAttachmentPolicy.kind(forFileName: "a.PNG") == .image, "an image is an image")
        expect(AIAttachmentPolicy.kind(forFileName: "a.pdf") == .pdf, "a PDF is a document")
        expect(AIAttachmentPolicy.kind(forFileName: "a.md") == .text, "markdown inlines")
        expect(AIAttachmentPolicy.kind(forFileName: "a.swift") == .text, "so does source")
        expect(AIAttachmentPolicy.kind(forFileName: "a.zip") == nil, "an archive is refused")
        expect(AIAttachmentPolicy.kind(forFileName: "a.mp4") == nil, "and so is video")
        expect(AIAttachmentPolicy.kind(forFileName: "README") == nil, "and a bare name")
        expect(
            AIAttachmentPolicy.mimeType(forFileName: "a.pdf") == AIAttachmentPolicy.pdfMIMEType,
            "only a PDF gets a mime type a transport reads")
        expect(
            AIAttachmentPolicy.mimeType(forFileName: "a.csv") == "text/plain",
            "an inlined file is text, whatever its extension")
    }

    static func markdownParsesStreamingFriendlyBlocks() {
        let blocks = MarkdownBlock.parse(
            """
            # Heading

            - first
            - [x] done

            ```swift
            let answer = 42
            """)
        expect(blocks.count == 3, "heading list and open code fence become blocks")
        if case .heading(let level, let text) = blocks.first {
            expect(level == 1 && text == "Heading", "headings preserve level and text")
        } else {
            expect(false, "the first block is a heading")
        }
        if case .code(let language, let text) = blocks.last {
            expect(language == "swift", "code fences preserve their language")
            expect(text == "let answer = 42", "an open streaming fence closes at the end")
        } else {
            expect(false, "the final block is code")
        }
    }

    static func markdownParsesTablesQuotesAndLists() {
        let table = MarkdownBlock.parse(
            """
            | Name | Qty |
            |:-----|----:|
            | a \\| b | 1 |
            | short |
            """)
        expect(
            table == [
                .table(
                    .init(
                        header: ["Name", "Qty"], alignments: [.leading, .trailing],
                        rows: [["a \\| b", "1"], ["short", ""]]))
            ],
            "a pipe table keeps alignments, escaped pipes and pads a short row")
        expect(
            MarkdownBlock.parse("prose\n---") == [.paragraph("prose"), .rule],
            "a bare dash line under prose is a rule, never a table delimiter")

        let quote = MarkdownBlock.parse("> quoted\n> - item\nlazy")
        expect(
            quote == [
                .quote([
                    .paragraph("quoted"),
                    .bulletList([.init(blocks: [.paragraph("item\nlazy")], checked: nil)])
                ])
            ],
            "a quote nests blocks, and a lazy line continues the innermost paragraph")

        let nested = MarkdownBlock.parse(
            """
            - parent
              - child
            - [ ] open
            - [x] closed

            3. three
            4. four
            """)
        expect(
            nested == [
                .bulletList([
                    .init(
                        blocks: [
                            .paragraph("parent"),
                            .bulletList([.init(blocks: [.paragraph("child")], checked: nil)])
                        ], checked: nil),
                    .init(blocks: [.paragraph("open")], checked: false),
                    .init(blocks: [.paragraph("closed")], checked: true)
                ]),
                .numberedList(
                    start: 3,
                    items: [
                        .init(blocks: [.paragraph("three")], checked: nil),
                        .init(blocks: [.paragraph("four")], checked: nil)
                    ])
            ],
            "lists nest by indent, carry task boxes and keep their start number")

        let loose = MarkdownBlock.parse("- a\n\n  b\n- c")
        expect(
            loose == [
                .bulletList([
                    .init(blocks: [.paragraph("a"), .paragraph("b")], checked: nil),
                    .init(blocks: [.paragraph("c")], checked: nil)
                ])
            ],
            "an indented paragraph after a blank line stays inside its item")
    }

    static func markdownKeepsCommonMarkEdges() {
        expect(
            MarkdownBlock.parse("# C#\n## Title ##\n####### seven") == [
                .heading(level: 1, text: "C#"), .heading(level: 2, text: "Title"),
                .paragraph("####### seven")
            ],
            "closing hashes strip only when spaced off, and seven hashes is prose")
        expect(
            MarkdownBlock.parse("text\n2. two") == [.paragraph("text\n2. two")],
            "only a list starting at 1 may interrupt a paragraph")
        expect(
            MarkdownBlock.parse("text\n1. one") == [
                .paragraph("text"),
                .numberedList(start: 1, items: [.init(blocks: [.paragraph("one")], checked: nil)])
            ],
            "a list starting at 1 does interrupt a paragraph")
        expect(
            MarkdownBlock.parse("~~~\nlet x = `y`\n~~~\nafter") == [
                .code(language: nil, text: "let x = `y`"), .paragraph("after")
            ],
            "a tilde fence closes on its own run and resumes prose")
        expect(
            MarkdownBlock.parse("````\n```\n````") == [.code(language: nil, text: "```")],
            "a shorter backtick run inside a fence is content, not its close")
        expect(
            MarkdownBlock.parse("one\ntwo\n\nthree") == [
                .paragraph("one\ntwo"), .paragraph("three")
            ],
            "soft breaks stay inside a paragraph and a blank line ends it")
    }

    static func markdownFindsMathButNotPrices() {
        let pieces = MarkdownMath.pieces(of: #"Roots \(x^2\) and $y$, at $5 or $10, \$3, `$z$`."#)
        expect(
            pieces == [
                .text("Roots "), .math(tex: "x^2", display: false, source: #"\(x^2\)"#), .text(" and "),
                .math(tex: "y", display: false, source: "$y$"),
                .text(#", at $5 or $10, \$3, `$z$`."#)
            ],
            "inline math is found, while prices, an escaped dollar and code stay text: \(pieces)")
        expect(
            MarkdownMath.pieces(of: "US$5 and US$6") == [.text("US$5 and US$6")]
                && MarkdownMath.pieces(of: "$x$5") == [.text("$x$5")],
            "a dollar pair around prose or before a digit is currency")
        expect(
            MarkdownMath.pieces(of: #"so \(x + \frac{1}{"#) == [.text("so "), .unclosed(#"\(x + \frac{1}{"#)],
            "an equation still streaming in shows as its source")
        let inline = MarkdownBlock.inline(#"**Bold \(x\)** and $\foo$ and [$y$](https://example.com)"#)
        let formulas = inline.runs.compactMap { $0[MathFormula.Attribute.self]?.source }
        expect(
            String(inline.characters) == "Bold \u{FFFC} and $\\foo$ and \u{FFFC}"
                && formulas == [#"\(x\)"#, "$y$"],
            "a formula is one character in emphasis or a link, and one that won't typeset is its source")
        expect(
            inline.runs.contains { $0[MathFormula.Attribute.self] != nil && $0.link != nil },
            "a formula inside a link keeps the link")
    }

    static func markdownDisplayMathIsItsOwnBlock() {
        let blocks = MarkdownBlock.parse("The formula:\n$$\nx = \\frac{a}{b}\n$$\nwhere $b \\ne 0$.")
        guard blocks.count == 3, case .math(let formula) = blocks[1] else {
            expect(false, "a $$ block splits its paragraph, got \(blocks)")
            return
        }
        expect(
            formula.display && formula.source == "$$\nx = \\frac{a}{b}\n$$"
                && blocks[0] == .paragraph("The formula:") && blocks[2] == .paragraph("where $b \\ne 0$."),
            "display math takes its lines with their delimiters, and the prose around it stays prose")
        expect(
            MarkdownBlock.parse(#"\[ \unknown{x} \]"#) == [.code(language: "latex", text: #"\unknown{x}"#)],
            "a display equation outside the subset shows as LaTeX source")
        expect(
            MarkdownBlock.parse("$$\n\\frac{a}{b") == [.paragraph("$$\n\\frac{a}{b")],
            "an unclosed display equation waits as a paragraph")
        expect(
            MarkdownBlock.parse("$$x$$ is small") == [.paragraph("$$x$$ is small")],
            "an equation followed by prose on its line is inline")
        expect(
            MarkdownBlock.parse("```\n$$x$$\n```") == [.code(language: nil, text: "$$x$$")],
            "math inside a fence stays code")
        let message = ChatMessage(role: .assistant, text: "apple $a$\n\n$$apple$$\n\napple")
        expect(
            ChatFindIndex.occurrences(of: "apple", in: [message]).count == 2,
            "find searches the prose, never an equation's source")
    }

    static func mathParsesTheSupportedSubsetOnly() {
        let supported = [
            #"\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#, #"\sum_{i=1}^{n} i"#, #"\int_0^\infty e^{-x^2}\,dx"#,
            #"\lim_{x \to 0} \frac{\sin x}{x}"#, #"\left( \frac{a}{b} \right)^2"#, #"\binom{n}{k}"#,
            #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#, #"\sqrt[3]{8}"#, #"f''(x)"#,
            #"\begin{cases} x & \text{if } x > 0 \\ -x & \text{else} \end{cases}"#,
            #"\begin{aligned} a &= b \\ &= c \end{aligned}"#, #"\mathbb{R}^n \vec{v} \hat{x}"#,
            #"\boxed{x = 5} \overline{AB} \not= \operatorname{rank}(A)"#
        ]
        for tex in supported {
            expect(MathNode.parse(tex) != nil, "\(tex) typesets")
        }
        let refused = [
            #"\foo{x}"#, "x^2^3", #"\frac{1}{"#, #"\left( x"#, #"\begin{tikzcd}\end{tikzcd}"#,
            String(repeating: "{", count: 60) + String(repeating: "}", count: 60),
            String(repeating: "x", count: MathNode.maximumLength + 1)
        ]
        for tex in refused {
            expect(MathNode.parse(tex) == nil, "\(tex.prefix(40)) is refused and shows as source")
        }
        expect(
            MathNode.parse("a & b") != nil && MathNode.parse(#"a \\ b"#) != nil,
            "a top-level & or \\\\ lays out as aligned or gathered rows")
        expect(
            MathNode.parse(#"\alpha x \mathbb{R}"#)
                == .row([.symbol("𝛼", .ord), .symbol("𝑥", .ord), .row([.symbol("ℝ", .ord)])]),
            "letters take the math italic, and \\mathbb its double-struck form")
    }

    static func mathStillArrivingIsHeldBackOnlyAtTheEnd() {
        let display = "The formula:\n$$\n\\frac{a}{b"
        expect(
            MarkdownBlock.parse(display, midStream: true) == [.paragraph("The formula:"), .pendingMath],
            "a display equation still arriving is a placeholder, not its half-written source")
        expect(
            MarkdownBlock.parse(display) == [.paragraph("The formula:"), .paragraph("$$\n\\frac{a}{b")],
            "once the reply has finished, an unclosed display equation shows as source")
        expect(
            MarkdownBlock.parse("Roots \\(x + \\frac{1}{", midStream: true) == [.paragraph("Roots ")]
                && MarkdownBlock.parse("\\(x", midStream: true).isEmpty,
            "an inline equation still arriving is held back from the text")
        expect(
            MarkdownBlock.parse("Roots \\(x + \\frac{1}{") == [.paragraph("Roots \\(x + \\frac{1}{")],
            "a finished reply keeps an unclosed inline opener as source")
        expect(
            MarkdownBlock.parse("It costs $5 and $x", midStream: true) == [.paragraph("It costs $5 and $x")],
            "a lone dollar may be a price, so nothing after it is ever held back")
        expect(
            MarkdownBlock.parse("A stray \\( here\n\nMore \\(y", midStream: true) == [
                .paragraph("A stray \\( here"), .paragraph("More ")
            ],
            "an opener the stream has moved past is a stray and stays visible")
        expect(
            MarkdownBlock.parse("$$\nx\n\nafter", midStream: true) == [
                .paragraph("$$\nx"), .paragraph("after")
            ],
            "a blank line inside $$ proves it stray, even mid-stream")
        expect(
            MarkdownBlock.parse("Text\n$$\nx = \\frac{a}{b}.\n", midStream: true) == [
                .paragraph("Text"), .pendingMath
            ]
                && MarkdownBlock.parse("$$\nx\n\n", midStream: true) == [.pendingMath],
            "a stream that has just sent a newline, or two, is still inside its equation")
        expect(
            MarkdownBlock.parse("Roots \\(x +\n", midStream: true) == [.paragraph("Roots ")],
            "an inline equation is still held back when a newline is the last thing to arrive")
        expect(
            MarkdownBlock.parse("Text\n$$\nx = \\frac{a}{b}.\n") == [
                .paragraph("Text"), .paragraph("$$\nx = \\frac{a}{b}.")
            ],
            "a finished reply ending in a newline still shows an unclosed equation as source")
        expect(
            MarkdownBlock.parse("- item\n  $$\n  x", midStream: true) == [
                .bulletList([.init(blocks: [.paragraph("item"), .pendingMath], checked: nil)])
            ],
            "a list item still being written holds its equation back too")
        expect(
            MarkdownBlock.parse("- a\n  $$\n  x\n- b", midStream: true) == [
                .bulletList([
                    .init(blocks: [.paragraph("a"), .paragraph("$$\nx")], checked: nil),
                    .init(blocks: [.paragraph("b")], checked: nil)
                ])
            ],
            "an item the stream has left behind shows its unclosed equation")
        expect(
            MarkdownBlock.parse("## Area \\(\\pi r", midStream: true) == [.heading(level: 2, text: "Area ")],
            "a heading still arriving holds back its equation")
        expect(
            MarkdownBlock.parse("| A | B |\n| - | - |\n| 1 | \\(x", midStream: true) == [
                .table(.init(header: ["A", "B"], alignments: [.leading, .leading], rows: [["1", ""]]))
            ],
            "only the table cell being written holds back its equation")
        guard case .math? = MarkdownBlock.parse("$$x$$", midStream: true).first,
            MarkdownBlock.inline("Roots \\(x\\)").runs.contains(where: {
                $0[MathFormula.Attribute.self] != nil
            })
        else {
            expect(false, "an equation that has closed renders mid-stream")
            return
        }
        var message = ChatMessage(role: .assistant, text: "apple\n$$\napple", state: .streaming)
        expect(
            ChatFindIndex.occurrences(of: "apple", in: [message]).count == 1,
            "find skips an equation still arriving, as the transcript does")
        message.state = .complete
        expect(
            ChatFindIndex.occurrences(of: "apple", in: [message]).count == 2,
            "and searches its source once the reply has finished")
        expect(
            message.isArriving(segmentAt: 0, of: 1) == false
                && ChatMessage(role: .assistant, text: "", state: .streaming).isArriving(segmentAt: 1, of: 2)
                && !ChatMessage(role: .assistant, text: "", state: .streaming).isArriving(
                    segmentAt: 0, of: 2),
            "only the last segment of a streaming reply is still arriving")
    }

    static func segmentsClampSearchOffsets() {
        let message = ChatMessage(
            role: .assistant, text: "abc",
            searches: [
                ChatSearch(query: nil, isComplete: true, textOffset: 0, sequence: 0),
                ChatSearch(query: "late", isComplete: true, textOffset: 99, sequence: 1)
            ])
        expect(
            message.segments == [
                .search(ChatSearch(query: nil, isComplete: true, textOffset: 0, sequence: 0)),
                .text("abc"),
                .search(ChatSearch(query: "late", isComplete: true, textOffset: 99, sequence: 1))
            ],
            "a search at the start or past the end never produces an empty text segment")
    }

    static func referencesAreTheLinksAReplyCites() {
        let reply = """
            See [the Swift book](https://www.swift.org/documentation/tspl/) and \
            https://forums.swift.org/t/example/42. Also https://www.swift.org/documentation/tspl.

            ```sh
            curl https://example.com/not-a-source
            ```
            """
        let references = ChatReferences.extract(from: reply)
        expect(references.count == 2, "a page cited twice is one source, got \(references.count)")
        expect(
            references.first?.title == "the Swift book"
                && references.first?.host == "swift.org",
            "a Markdown link keeps its own name and a readable host")
        expect(
            references.last?.url.absoluteString == "https://forums.swift.org/t/example/42",
            "a bare URL is a source too, its trailing full stop left out")
        expect(
            !references.contains { $0.host == "example.com" },
            "a URL inside a code sample is not a source")
        expect(ChatReferences.extract(from: "No links here.").isEmpty, "plain prose cites nothing")
    }

    static func findWalksMatchesAndWraps() {
        let reply = ChatMessage(
            role: .assistant,
            text: "**Apples** and apples.\n\n- An apple a day\n\n```choices\nMore apples\n```",
            reasoning: [ChatReasoning(text: "Think of apples", textOffset: 0, duration: 1)])
        let messages = [
            ChatMessage(role: .user, text: "Tell me about apples"),
            ChatMessage(role: .assistant, text: "Pears are nice"),
            reply
        ]
        let find = ChatFindState()
        find.query = " apple "
        let found = find.occurrences(in: messages)
        expect(found.count == 5, "every word is a stop of its own, not every message, got \(found.count)")
        expect(
            found.map(\.messageID) == [messages[0].id] + Array(repeating: reply.id, count: 4),
            "matches run in reading order across messages")
        expect(
            found[1].leaf == [0] && found[2].leaf == [1, 0]
                && found[3] == ChatFindOccurrence(messageID: reply.id, leaf: [1, 0], index: 1)
                && found[4].leaf == [1, 1, 0, 0],
            "a reply's thinking comes first, then each drawn text numbers its own matches")
        let table = ChatMessage(role: .assistant, text: "| Q | A |\n| - | - |\n| One | Yes |\n| Two | Yes |")
        let cells = ChatFindIndex.occurrences(of: "yes", in: [table])
        expect(
            cells.map(\.leaf) == [[0, 0, 1, 1], [0, 0, 2, 1]],
            "identical cells are two places, so each is its own match: \(cells.map(\.leaf))")
        var grown = messages
        grown[1].text += " and apples"
        expect(
            find.occurrences(in: grown).count == 6 && find.occurrences(in: messages).count == 5,
            "a reply that grows is searched again, the rest come from the cache")
        find.step(-1, in: messages)
        expect(find.currentOccurrence(in: found) == found.last, "stepping back from the first wraps")
        find.query = "more apples"
        expect(find.occurrences(in: messages).isEmpty, "a choices fence is not text find can see")
        expect(find.current == 0, "a new query starts at its first match")
    }

    static func citationsCloseTheSentenceThatCitedThem() {
        let text = MarkdownBlock.inline(
            "Read [the guide](https://example.com/guide) first. Then see https://example.org/faq.")
        let numbers = ChatReferences.numbers(
            for: ChatReferences.extract(
                from: "[g](https://example.com/guide) https://example.org/faq"))
        let anchors = ChatCitations.anchors(in: text, numbers: numbers)
        let plain = String(text.characters)
        expect(
            anchors.map(\.number) == [1, 2],
            "each cited source is numbered as its chip is, got \(anchors.map(\.number))")
        expect(
            anchors.map(\.offset) == [
                plain.distance(from: plain.startIndex, to: plain.range(of: "first.")!.upperBound),
                plain.count
            ],
            "a number lands after the full stop of the sentence that cited it")
        expect(
            ChatCitations.anchors(in: text, numbers: [:]).isEmpty,
            "a reply with no sources gets no numbers")
    }

    static func choicesComeOutOfTheirFence() {
        let reply = "Which one?\n\n```choices\n- Summarise it\n2. Translate it\n\n```\nThanks."
        let split = ChatChoices.split(reply)
        expect(split.choices == ["Summarise it", "Translate it"], "a fence's lines are the choices")
        expect(split.text == "Which one?\n\nThanks.", "the fence never shows as prose")
        let streaming = ChatChoices.split("Pick:\n```choices\nA\nB")
        expect(
            streaming.choices == ["A", "B"] && streaming.text == "Pick:",
            "an unclosed fence is already hidden while it streams")
        let code = "Use this:\n```swift\nlet choices = 1\n```"
        expect(ChatChoices.split(code).choices.isEmpty, "an ordinary code fence is not a choice list")
        let inline = ChatChoices.split("Say ```choices``` to me")
        expect(inline.choices.isEmpty, "a fence mid-line is prose, not choices")

        // What Apple Intelligence wrote: no fence, a `choices` line over a list.
        let unfenced = ChatChoices.split(
            "Here are a few ways I can help:\n\n* Open it\n\nchoices\n\n- Open Quick AI\n- Open AI Chat\n")
        expect(
            unfenced.choices == ["Open Quick AI", "Open AI Chat"]
                && unfenced.text == "Here are a few ways I can help:\n\n* Open it",
            "a bare `choices` label over a closing list is a choice list: \(unfenced)")
        expect(
            ChatChoices.split("**Choices:**\n1. Yes\n2. No").choices == ["Yes", "No"],
            "the label may be bold, capitalised or end in a colon")
        let proseAfter = "choices\n- A\n- B\n\nThat is all."
        expect(
            ChatChoices.split(proseAfter).choices.isEmpty, "a list followed by prose is not the reply's end")
        expect(
            ChatChoices.split("Your choices matter.\n- A").choices.isEmpty,
            "the word inside a sentence is not a label")
    }
}

// Standalone contract tests for the real Notes Markdown parser, edit plans and reveal policy.

import Foundation

@main
@MainActor
struct NoteMarkdownTests {
    private static var failures = 0

    static func main() async throws {
        testMarkdownParser()
        testMarkdownEditing()
        testMarkdownFormatting()
        testRevealPolicy()

        print(failures == 0 ? "Notes tests passed" : "\(failures) tests failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static func testMarkdownParser() {
        let tiled = ["a\nb\n", "a\r\nb", "\n\n", "x", "a\u{2029}b\rc"]
        check("an empty source is one empty line", NoteMarkdownParser.parse("").lines.map(\.kind) == [.blank])
        for source in tiled {
            let lines = NoteMarkdownParser.parse(source).lines
            let string = source as NSString
            var location = 0
            var agrees = true
            for line in lines {
                agrees = agrees && line.range == string.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(line.range)
            }
            check("lines tile \(source.debugDescription) like NSString", agrees && location == string.length)
        }
        check(
            "a final terminator makes the empty row a real line",
            NoteMarkdownParser.parse("a\n").lines.map(\.kind) == [.paragraph, .blank])
        let crlf = NoteMarkdownParser.parse("# Hi\r\nnext").lines
        check(
            "a CRLF terminator belongs to the range, never the content",
            crlf[0].range == NSRange(location: 0, length: 6)
                && crlf[0].contentRange == NSRange(location: 2, length: 2))

        check(
            "each line kind is recognised",
            kinds("para\n\n# One\n###### Six\n- a\n* b\n+ c\n1. d\n12) e\n- [ ] f\n- [x] g\n> q\n>> r\n---")
                == [
                    .paragraph, .blank, .heading(level: 1), .heading(level: 6), .bullet, .bullet, .bullet,
                    .ordered(number: 1), .ordered(number: 12), .task(checked: false),
                    .task(checked: true), .quote(depth: 1), .quote(depth: 2), .rule
                ])
        check(
            "rules win over lists, and hashtags stay paragraphs",
            kinds("- - -\n***\n___\n#hashtag\n####### seven\n3.14 pi\n-\n#")
                == [.rule, .rule, .rule, .paragraph, .paragraph, .paragraph, .paragraph, .heading(level: 1)])
        check(
            "list markers become lists only after a separator",
            kinds("-\n- \n*\n* \n+\n+ \n1.\n1. \n12)\n12) ")
                == [
                    .paragraph, .bullet, .paragraph, .bullet, .paragraph, .bullet,
                    .paragraph, .ordered(number: 1), .paragraph, .ordered(number: 12)
                ])
        check(
            "four spaces keep a rule literal, as they already do a heading and a quote",
            kinds("   ---\n    ---\n    # not a heading\n    > not a quote")
                == [.rule, .paragraph, .paragraph, .paragraph])
        check("quote nesting counts every marker", kinds("> > nested") == [.quote(depth: 2)])

        let heading = NoteMarkdownParser.parse("## Title ##").lines[0]
        check(
            "a heading marker covers the hashes and one space; a closing run stays content",
            heading.markerRange == NSRange(location: 0, length: 3)
                && substring("## Title ##", heading.contentRange) == "Title ##")

        let tasks = "- [ ] a\n- [x] b\n- [X] c\n-[ ] d\n- [y] e\n  - [ ]"
        let taskLines = NoteMarkdownParser.parse(tasks).lines
        check(
            "task checkboxes cover the bracket triple",
            taskLines[0].checkboxRange == NSRange(location: 2, length: 3)
                && substring(tasks, taskLines[1].checkboxRange) == "[x]"
                && substring(tasks, taskLines[2].checkboxRange) == "[X]"
                && taskLines[5].checkboxRange == NSRange(location: 43, length: 3))
        check(
            "malformed boxes are not tasks",
            taskLines[3].kind == .paragraph && taskLines[4].kind == .bullet
                && taskLines[4].checkboxRange == nil)
        check(
            "a task marker runs through the space after the box",
            substring(tasks, taskLines[0].markerRange) == "- [ ] "
                && substring(tasks, taskLines[0].contentRange) == "a")

        check(
            "two-space, four-space and tab indentation nest by the indent stack",
            levels("- a\n  - b\n    - c\n- d") == [0, 1, 2, 0]
                && levels("1. a\n    1. b\n\t- c") == [0, 1, 1])
        check("a blank line keeps list depth", levels("- a\n  - b\n\n  - c") == [0, 1, 0, 1])
        check("a paragraph resets list depth", levels("- a\n  - b\npara\n  - c") == [0, 1, 0, 0])

        let fenced = "```swift\n# not heading\n**x**\n````\nafter\n~~~\ncode"
        let fence = NoteMarkdownParser.parse(fenced)
        check(
            "fences mark their lines as code with no inlines",
            fence.lines.map(\.kind) == [
                .fenceOpen(language: "swift"), .code, .code, .fenceClose, .paragraph,
                .fenceOpen(language: nil), .code
            ] && fence.inlines(of: fence.lines[2]).isEmpty)
        check(
            "fence blocks list open through close, and an unclosed one runs to the end",
            fence.fenceBlocks == [0...3, 5...6])
        check(
            "a backtick fence never closes on tildes or a shorter run",
            kinds("````\n~~~~\n```\n````") == [.fenceOpen(language: nil), .code, .code, .fenceClose])
        check(
            "a backtick info string may not contain a backtick",
            kinds("``` a`b") == [.paragraph] && kinds("~~~ a`b") == [.fenceOpen(language: "a`b")])
        check(
            "fence lines hide whole, with an empty content range",
            fence.lines[0].markerRange == NSRange(location: 0, length: 8)
                && fence.lines[0].contentRange.length == 0)

        check(
            "emphasis, strong, both and strikethrough",
            spans("**a** _b_ ***c*** ~~d~~") == [
                .init(.strong, "a"), .init(.emphasis, "b"), .init(.strongEmphasis, "c"),
                .init(.strikethrough, "d")
            ])
        check(
            "nested spans are separate values, outer first",
            spans("**bold _both_**") == [.init(.strong, "bold _both_"), .init(.emphasis, "both")])
        check("unmatched delimiters stay text", spans("**open and * alone ~~no").isEmpty)
        check("intraword underscores stay text", spans("snake_case_name").isEmpty)
        check("whitespace-flanked delimiters do not open", spans("a * b * c").isEmpty)
        check("an escape stops a delimiter", spans("\\*not\\* *yes*") == [.init(.emphasis, "yes")])
        let strongLine = NoteMarkdownParser.parse("x **a** y")
        let strong = strongLine.inlines(of: strongLine.lines[0])[0]
        check(
            "delimiter markers are hidden runs",
            strong.markerRanges == [NSRange(location: 2, length: 2), NSRange(location: 5, length: 2)]
                && strong.range == NSRange(location: 2, length: 5))

        check(
            "code spans match runs of equal length and are not parsed further",
            spans("``a ` **b**`` `c`") == [.init(.code, "a ` **b**"), .init(.code, "c")])
        check("an unclosed backtick is text", spans("`open **b**") == [.init(.strong, "b")])

        let linkSource = "see [**a** b](https://x.com/(y)) now"
        check(
            "a link parses its label and keeps balanced parentheses",
            spans(linkSource) == [
                .init(.link(destination: "https://x.com/(y)"), "**a** b"), .init(.strong, "a")
            ])
        let linkLine = NoteMarkdownParser.parse(linkSource)
        let link = linkLine.inlines(of: linkLine.lines[0])[0]
        check(
            "a link hides its bracket and its destination",
            link.markerRanges.map { substring(linkSource, $0) } == ["[", "](https://x.com/(y))"])
        check("an image stays literal", spans("![alt **x**](a.png)").isEmpty)
        check("a destination with a space is not a link", spans("[a](b c)").isEmpty)

        check(
            "bare URLs link with trailing punctuation trimmed",
            spans("go https://a.com/x. or (http://b.org/p_(1)), ok")
                == [.init(.autolink, "https://a.com/x"), .init(.autolink, "http://b.org/p_(1)")])
        check(
            "bare URLs never link inside code, a link or a word",
            spans("`https://a.com` [https://b.com](https://c.com) xhttps://d.com")
                == [
                    .init(.code, "https://a.com"), .init(.link(destination: "https://c.com"), "https://b.com")
                ])

        let table = "| Folder | Holds |\n| --- | :---: |\n| `App/` | **root** |\nnot | a row\n\n| after |"
        check(
            "a table is a header, a matching delimiter row and the pipe rows after it",
            kinds(table) == [.table, .table, .table, .table, .blank, .paragraph])
        let tableMarkdown = NoteMarkdownParser.parse(table)
        check(
            "table rows stay literal, with no inline spans",
            tableMarkdown.lines.allSatisfy { tableMarkdown.inlines(of: $0).isEmpty })
        check(
            "outer pipes are optional and alignment colons are allowed",
            kinds("a | b\n:-- | --:\nc | d") == [.table, .table, .table])
        check(
            "a pipe row without a delimiter row, or with the wrong cell count, is a paragraph",
            kinds("| a | b |\n| c | d |") == [.paragraph, .paragraph]
                && kinds("| a | b |\n| --- |") == [.paragraph, .paragraph])
        check(
            "a table inside a fence stays code, and a list line never starts one",
            kinds("```\n| a |\n| --- |\n```") == [.fenceOpen(language: nil), .code, .code, .fenceClose]
                && kinds("- | a |\n| --- |") == [.bullet, .paragraph])

        let emoji = "🧑🏽‍💻 **e\u{301}** 👍🏻"
        let emojiLine = NoteMarkdownParser.parse(emoji)
        let emojiSpan = emojiLine.inlines(of: emojiLine.lines[0])[0]
        check(
            "surrogate pairs and combining marks keep exact UTF-16 ranges",
            substring(emoji, emojiSpan.range) == "**e\u{301}**"
                && substring(emoji, emojiSpan.contentRange) == "e\u{301}")

        let index = NoteMarkdownParser.parse("ab\ncd\n")
        check(
            "line lookup covers the start, a terminator and the end of the source",
            index.lineIndex(at: 0) == 0 && index.lineIndex(at: 2) == 0 && index.lineIndex(at: 3) == 1
                && index.lineIndex(at: 6) == 2 && index.lineIndex(at: 7) == nil)
        check(
            "an empty range touches its line; a range ending at a line start does not reach it",
            index.lineIndexes(intersecting: NSRange(location: 2, length: 0)) == 0..<1
                && index.lineIndexes(intersecting: NSRange(location: 0, length: 3)) == 0..<1
                && index.lineIndexes(intersecting: NSRange(location: 1, length: 3)) == 0..<2)
    }

    private static func testMarkdownEditing() {
        check("Return continues a bullet", edit(.newline, "- item|") == "- item\n- |")
        check("Return continues an ordered item", edit(.newline, "1. one|") == "1. one\n2. |")
        check("Return keeps a parenthesis delimiter", edit(.newline, "3) c|") == "3) c\n4) |")
        check("Return continues a task unchecked", edit(.newline, "* [x] done|") == "* [x] done\n* [ ] |")
        check("Return moves text after the caret", edit(.newline, "- ab|cd") == "- ab\n- |cd")
        check("Return keeps indentation", edit(.newline, "- a\n    - b|") == "- a\n    - b\n    - |")
        check("Return on an empty item leaves the list", edit(.newline, "- a\n- |") == "- a\n|")
        check("Return on an empty nested item outdents", edit(.newline, "- a\n    - |") == "- a\n- |")
        check("Return continues a quote", edit(.newline, "> quote|") == "> quote\n> |")
        check("Return on an empty quote leaves it", edit(.newline, "> a\n> |") == "> a\n|")
        check(
            "Return is native in a paragraph, in code and over a selection",
            edit(.newline, "plain|") == nil && edit(.newline, "```\n- a|\n```") == nil
                && edit(.newline, "- «item»") == nil)
        check("Return is native inside a marker", edit(.newline, "-| item") == nil)

        check(
            "Backspace at content start outdents a nested item",
            edit(.deleteBackward, "- a\n  - |b") == "- a\n- |b")
        check("Backspace at content start removes a top marker", edit(.deleteBackward, "- [ ] |b") == "|b")
        check("Backspace removes a quote marker", edit(.deleteBackward, "> |q") == "|q")
        check("Backspace is native past content start", edit(.deleteBackward, "- b|c") == nil)

        check("Tab nests a list item", edit(.indent, "- a\n- b|") == "- a\n    - b|")
        check(
            "Tab nests every selected item and keeps the selection on its text",
            edit(.indent, "- a\n- «b\n- c»") == "- a\n    - «b\n    - c»")
        check(
            "Tab nests under a sibling at the same depth",
            edit(.indent, "- a\n    - b\n    - c|") == "- a\n    - b\n        - c|")
        check(
            "Tab refuses a first item and a level jump",
            edit(.indent, "- a|") == nil && edit(.indent, "- a\n- b\n    - c\n- d\n        - e|") == nil)
        check("Tab is native in a paragraph", edit(.indent, "- a\npara|") == nil)
        check("Shift-Tab removes one indent step", edit(.outdent, "- a\n    - b|") == "- a\n- b|")
        check("Shift-Tab removes a tab", edit(.outdent, "- a\n\t- b|") == "- a\n- b|")
        check("Shift-Tab with nothing to remove is native", edit(.outdent, "- a|") == nil)

        check(
            "inserting an item renumbers the run",
            edit(.newline, "1. a|\n2. b\n3. c") == "1. a\n2. |\n3. b\n4. c")
        check("a run keeps its first number", edit(.newline, "5. a|\n6. b") == "5. a\n6. |\n7. b")
        check(
            "nesting an item renumbers the run it leaves",
            edit(.indent, "1. a\n2. b\n3. c|\n4. d") == "1. a\n2. b\n    3. c|\n3. d")
        check(
            "nested runs restart from their own first number under a shallower item",
            edit(.newline, "1. a|\n    1. x\n    2. y\n2. b\n    5. z\n    9. w")
                == "1. a\n2. |\n    1. x\n    2. y\n3. b\n    5. z\n    6. w")
        check(
            "a paragraph ends a run",
            edit(.newline, "1. a|\npara\n7. b") == "1. a\n2. |\npara\n7. b")
        check(
            "renumbering keeps each item's delimiter",
            edit(.deleteBackward, "1. a\n2) |b\n3) c") == "1. a\n|b\n3) c")
        check(
            "renumbering crosses blank lines",
            edit(.newline, "1. a|\n\n2. b") == "1. a\n2. |\n\n3. b")
        check(
            "a leading-zero marker continues from its own delimiter",
            edit(.newline, "007. a|") == "007. a\n8. |")
        check(
            "renumbering replaces a leading-zero marker whole",
            edit(.newline, "1. a|\n007. b") == "1. a\n2. |\n3. b")

        check("⌘B wraps a selection", edit(.toggleInline(.bold), "a «bold» b") == "a **«bold»** b")
        check(
            "⌘B trims whitespace before wrapping",
            edit(.toggleInline(.bold), "a« bold »b") == "a **«bold»** b")
        check("⌘B unwraps exact content", edit(.toggleInline(.bold), "a **«bold»** b") == "a «bold» b")
        check("⌘B unwraps a selected span", edit(.toggleInline(.bold), "a «**bold**» b") == "a «bold» b")
        check("⌘B unwraps from the caret", edit(.toggleInline(.bold), "**bo|ld**") == "bo|ld")
        check(
            "⌘I wraps the word at the caret",
            edit(.toggleInline(.italic), "say wo|rd now") == "say _wo|rd_ now")
        check("⌘E inserts a pair", edit(.toggleInline(.code), "a | b") == "a `|` b")
        check("⇧⌘X strikes through", edit(.toggleInline(.strikethrough), "«gone»") == "~~«gone»~~")
        check(
            "unwrapping bold from bold italic keeps the italic",
            edit(.toggleInline(.bold), "***«both»***") == "*«both»*"
                && edit(.toggleInline(.italic), "***«both»***") == "**«both»**")
        check("⌘E pads a span holding a backtick", edit(.toggleInline(.code), "«a`b»") == "`` «a`b» ``")
        check("⌘B across lines does nothing", edit(.toggleInline(.bold), "«a\nb»") == nil)
        check("⌘B on an empty note inserts a pair", edit(.toggleInline(.bold), "|") == "**|**")
        check(
            "⌘B on the row after a final newline stays there",
            edit(.toggleInline(.bold), "# T\n|") == "# T\n**|**")
        check("⌘B inside a code block does nothing", edit(.toggleInline(.bold), "```\nco|de\n```") == nil)
        check(
            "⌘B inside a table does nothing",
            plan(.toggleInline(.bold), "a | b\n--- | ---\nc | d", caret: 17) == nil)

        check("⌘K wraps text and selects the URL", edit(.toggleLink, "see «docs»") == "see [docs](«url»)")
        check(
            "⌘K on a selected URL puts the caret in the label",
            edit(.toggleLink, "«https://a.com»") == "[|](https://a.com)")
        check("⌘K inside a link unwraps it", edit(.toggleLink, "[do|cs](https://a.com)") == "do|cs")
        check("⌘K with nothing selected inserts a link", edit(.toggleLink, "a |") == "a [|](url)")

        check("⌥⌘1 sets a heading", edit(.setHeading(level: 1), "Tit|le") == "# Tit|le")
        check("⌥⌘2 changes the level", edit(.setHeading(level: 2), "# Tit|le") == "## Tit|le")
        check("repeating the level removes it", edit(.setHeading(level: 2), "## Tit|le") == "Tit|le")
        check("⌥⌘0 makes a paragraph", edit(.setHeading(level: 0), "### «Title»") == "«Title»")
        check(
            "headings apply per line and skip lists",
            edit(.setHeading(level: 1), "«a\n- b\nc»") == "# «a\n- b\n# c»")
        check("headings skip every non-text line", edit(.setHeading(level: 1), "- a|") == nil)

        check("⇧⌘8 adds a bullet", edit(.toggleList(.bullet), "item|") == "- item|")
        check("⇧⌘8 removes a bullet", edit(.toggleList(.bullet), "  - item|") == "  item|")
        check("⇧⌘9 swaps a bullet for a task", edit(.toggleList(.task), "* item|") == "* [ ] item|")
        check("⇧⌘8 on an empty line starts a list", edit(.toggleList(.bullet), "a\n|") == "a\n- |")
        check(
            "⇧⌘7 numbers a mixed selection and skips blank lines",
            edit(.toggleList(.ordered), "«a\n\n- b\n> c»") == "1. «a\n\n2. b\n> c»")
        check("⇧⌘8 on a quote does nothing", edit(.toggleList(.bullet), "> q|") == nil)

        let tasks = "- [ ] a\n- [x] b"
        check("a task toggles on", plan(.toggleTask(lineIndex: 0), tasks, caret: 12)?.replacement == "x")
        check(
            "a task toggles off without moving the selection",
            edit(.toggleTask(lineIndex: 1), "- [ ] a|\n- [x] b") == "- [ ] a|\n- [ ] b")
        check("only a task line toggles", plan(.toggleTask(lineIndex: 0), "- a", caret: 0) == nil)

        check("[] and a space make a task", edit(.typedSpace, "[]|") == "- [ ] |")
        check("[ ] and a space make a task", edit(.typedSpace, "  [ ]|") == "  - [ ] |")
        check(
            "the task rule only fires at line start in a paragraph",
            edit(.typedSpace, "a []|") == nil && edit(.typedSpace, "- []|") == nil
                && edit(.typedSpace, "[x]|") == nil)

        let url = NoteEditAction.pasteURL(" https://a.com/x \n")
        check(
            "pasting a URL over text links it",
            edit(url, "see «docs» now") == "see [docs](https://a.com/x)| now")
        check(
            "pasting links only a URL over a one-line selection",
            edit(.pasteURL("not a url"), "«docs»") == nil && edit(url, "«a\nb»") == nil
                && edit(url, "docs|") == nil)
        check(
            "pasting a URL inside code or a link is plain",
            edit(url, "`«code»`") == nil && edit(url, "[«label»](https://b.com)") == nil)

        check("⌥⌘C fences the caret's line", edit(.toggleCodeBlock, "a|b") == "```\na|b\n```")
        check(
            "⌥⌘C fences whole selected lines",
            edit(.toggleCodeBlock, "x «one\ntw»o") == "```\n«x one\ntwo»\n```")
        check("⌥⌘C in an empty note opens a block", edit(.toggleCodeBlock, "|") == "```\n|\n```")
        check("⌥⌘C on the last empty line opens a block", edit(.toggleCodeBlock, "a\n|") == "a\n```\n|\n```")
        check("⌥⌘C inside a block removes both fences", edit(.toggleCodeBlock, "```\nco|de\n```") == "co|de")
        check(
            "⌥⌘C keeps text after the block",
            edit(.toggleCodeBlock, "```swift\nx|\n```\nafter") == "x|\nafter")
        check("⌥⌘C on an unclosed block removes its fence", edit(.toggleCodeBlock, "```\nco|de") == "co|de")
        check("⌥⌘C on an empty block removes it", edit(.toggleCodeBlock, "a\n```|\n```") == "a\n|")
        check("⌥⌘C across a fence does nothing", edit(.toggleCodeBlock, "«a\n```\nb»\n```") == nil)

        check("⇧⌘B quotes the caret's line", edit(.toggleQuote, "a|") == "> a|")
        check("⇧⌘B quotes every selected line", edit(.toggleQuote, "«a\nb»") == "> «a\n> b»")
        check("⇧⌘B skips blank lines in a selection", edit(.toggleQuote, "«a\n\nb»") == "> «a\n\n> b»")
        check("⇧⌘B quotes an empty line", edit(.toggleQuote, "|") == "> |")
        check("⇧⌘B unquotes one level", edit(.toggleQuote, "> > a|") == "> a|")
        check("⇧⌘B unquotes a line", edit(.toggleQuote, "> a|") == "a|")
        check("⇧⌘B completes a mixed selection", edit(.toggleQuote, "«> a\nb»") == "«> a\n> b»")
        check("⇧⌘B keeps indentation", edit(.toggleQuote, "  a|") == "  > a|")
        check("⇧⌘B leaves code alone", edit(.toggleQuote, "```\nx|\n```") == nil)
    }

    private static func testMarkdownFormatting() {
        check("an empty note carries nothing", formatting("|") == .plain)
        var paragraph = NoteFormatting.plain
        paragraph.headingLevel = 0
        check("a paragraph reports only its level", formatting("pl|ain") == paragraph)
        check("a heading reports its level", formatting("## Ti|tle").headingLevel == 2)
        check("a heading and a paragraph share no level", formatting("«# a\nb»").headingLevel == nil)
        check("a caret in bold reports bold", formatting("**bo|ld**").inlineStyles == [.bold])
        check("bold italic reports both", formatting("***b|i***").inlineStyles == [.bold, .italic])
        check(
            "a selection of the whole span or its content reports bold",
            formatting("a «**bold**» b").inlineStyles == [.bold]
                && formatting("a **«bold»** b").inlineStyles == [.bold])
        check("part of a bold span is not bold", formatting("a **b«ol»d** b").inlineStyles == [])
        check("strikethrough reports", formatting("~~st|rike~~").inlineStyles == [.strikethrough])
        check("inline code reports", formatting("`co|de`").inlineStyles == [.code])
        check("a link reports", formatting("[la|bel](https://example.com)").isLink)
        check(
            "a bullet reports its list and no level",
            formatting("- item|").list == .bullet && formatting("- item|").headingLevel == nil)
        check("a list with a blank line between reports", formatting("«- a\n\n- b»").list == .bullet)
        check("mixed lists report none", formatting("«- a\n1. b»").list == nil)
        check("a task reports", formatting("- [ ] t|").list == .task)
        check("a quote reports", formatting("> q|").isQuote)
        check("a partly quoted selection is not a quote", !formatting("«> a\nb»").isQuote)
        check(
            "a code line reports the block and no inline styles",
            formatting("```\nc|\n```").isCodeBlock && formatting("```\nc|\n```").inlineStyles == [])

        let lit = [
            "**bo|ld**", "_it|al_", "~~st|rike~~", "`co|de`", "[la|bel](https://example.com)", "- it|em",
            "1. it|em", "- [ ] ta|sk", "> quo|te", "```\nco|de\n```", "## hea|ding"
        ]
        for marked in lit {
            let (source, selection) = unmark(marked)
            let actions = litActions(formatting(marked))
            check("\(marked) lights something", !actions.isEmpty)
            for action in actions {
                check(
                    "a lit \(action) removes syntax from \(marked)",
                    apply(action, source, selection: selection).map { $0.0.utf16.count < source.utf16.count }
                        == true)
            }
        }

        let plain = "plain wo|rd"
        let (source, selection) = unmark(plain)
        check("plain text lights nothing", litActions(formatting(plain)).isEmpty)
        let adding: [NoteEditAction] =
            NoteEditAction.InlineStyle.allCases.map { .toggleInline($0) }
            + [.toggleLink, .toggleList(.bullet), .toggleList(.ordered), .toggleList(.task)]
            + [.toggleQuote, .toggleCodeBlock, .setHeading(level: 1)]
        for action in adding {
            check(
                "an unlit \(action) adds syntax to plain text",
                apply(action, source, selection: selection).map { $0.0.utf16.count > source.utf16.count }
                    == true)
        }
    }

    private static func testRevealPolicy() {
        let source = "# a\nb **c**\n```\ncode\n```\nd\n"
        let markdown = NoteMarkdownParser.parse(source)
        func revealed(_ location: Int, _ length: Int = 0, focused: Bool = true) -> [Int] {
            Array(
                NoteRevealPolicy.revealedLines(
                    selection: NSRange(location: location, length: length), markdown: markdown,
                    isFocused: focused))
        }
        check("the caret reveals its line", revealed(5) == [1])
        check("a caret at the end of a line reveals that line", revealed(3) == [0])
        check("a selection reveals every line it touches", revealed(1, 5) == [0, 1])
        check("a caret inside a code block reveals both fences", revealed(17) == [2, 3, 4])
        check(
            "the row after a final newline reveals its own empty line",
            revealed((source as NSString).length) == [6])
        check(
            "a caret at the end of an unterminated note reveals the last line",
            Array(
                NoteRevealPolicy.revealedLines(
                    selection: NSRange(location: 3, length: 0), markdown: NoteMarkdownParser.parse("a\nb"),
                    isFocused: true)) == [1])
        check("an unfocused editor reveals nothing", revealed(5, focused: false).isEmpty)

        let revealedSet = IndexSet([1, 4])
        check(
            "a line inserted above shifts the revealed lines",
            NoteRevealPolicy.shifted(revealedSet, editedOldLines: 0..<1, editedNewLines: 0..<2)
                == IndexSet([0, 1, 2, 5]))
        check(
            "deleted lines drop out",
            NoteRevealPolicy.shifted(revealedSet, editedOldLines: 1..<3, editedNewLines: 1..<2)
                == IndexSet([1, 3]))
        check(
            "one line replaced by three reveals all three",
            NoteRevealPolicy.shifted(IndexSet([1]), editedOldLines: 1..<2, editedNewLines: 1..<4)
                == IndexSet([1, 2, 3]))
    }

    /// Applies an action to a source whose selection is marked `|` or `«…»`; marks the result.
    private static func edit(_ action: NoteEditAction, _ marked: String) -> String? {
        let (source, selection) = unmark(marked)
        guard case let (result, after)? = apply(action, source, selection: selection) else { return nil }
        let text = NSMutableString(string: result)
        if after.length == 0 {
            text.insert("|", at: after.location)
        } else {
            text.insert("»", at: NSMaxRange(after))
            text.insert("«", at: after.location)
        }
        return text as String
    }

    private static func unmark(_ marked: String) -> (String, NSRange) {
        var source = marked
        var selection = NSRange(location: 0, length: 0)
        if let caret = source.range(of: "|") {
            selection.location = source.utf16.distance(from: source.startIndex, to: caret.lowerBound)
            source.removeSubrange(caret)
        } else if let open = source.range(of: "«") {
            selection.location = source.utf16.distance(from: source.startIndex, to: open.lowerBound)
            source.removeSubrange(open)
            if let close = source.range(of: "»") {
                selection.length =
                    source.utf16.distance(from: source.startIndex, to: close.lowerBound) - selection.location
                source.removeSubrange(close)
            }
        }
        return (source, selection)
    }

    private static func formatting(_ marked: String) -> NoteFormatting {
        let (source, selection) = unmark(marked)
        return NoteMarkdownEditing.formatting(
            source: source, selection: selection, markdown: NoteMarkdownParser.parse(source))
    }

    /// The toggles a formatting's lit flags promise to undo.
    private static func litActions(_ formatting: NoteFormatting) -> [NoteEditAction] {
        var actions = NoteEditAction.InlineStyle.allCases
            .filter(formatting.inlineStyles.contains)
            .map { NoteEditAction.toggleInline($0) }
        if formatting.isLink { actions.append(.toggleLink) }
        if let list = formatting.list { actions.append(.toggleList(list)) }
        if formatting.isQuote { actions.append(.toggleQuote) }
        if formatting.isCodeBlock { actions.append(.toggleCodeBlock) }
        if let level = formatting.headingLevel, (1...6).contains(level) {
            actions.append(.setHeading(level: level))
        }
        return actions
    }

    private static func plan(_ action: NoteEditAction, _ source: String, caret: Int) -> NoteEditPlan? {
        NoteMarkdownEditing.plan(
            action, source: source, selection: NSRange(location: caret, length: 0),
            markdown: NoteMarkdownParser.parse(source))
    }

    private static func apply(
        _ action: NoteEditAction, _ source: String, selection: NSRange
    ) -> (String, NSRange)? {
        let markdown = NoteMarkdownParser.parse(source)
        guard
            let plan = NoteMarkdownEditing.plan(
                action, source: source, selection: selection, markdown: markdown)
        else { return nil }
        let result = (source as NSString).replacingCharacters(in: plan.range, with: plan.replacement)
        return (result, plan.selection)
    }

    private struct Span: Equatable {
        let kind: NoteMarkdown.Inline.Kind
        let text: String

        init(_ kind: NoteMarkdown.Inline.Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    private static func kinds(_ source: String) -> [NoteMarkdown.Line.Kind] {
        NoteMarkdownParser.parse(source).lines.map(\.kind)
    }

    private static func levels(_ source: String) -> [Int] {
        NoteMarkdownParser.parse(source).lines.map(\.level)
    }

    /// The first line's spans, each as its kind and the text of its content.
    private static func spans(_ source: String) -> [Span] {
        let markdown = NoteMarkdownParser.parse(source)
        let inlines = markdown.lines.first.map(markdown.inlines(of:)) ?? []
        return inlines.map { Span($0.kind, (source as NSString).substring(with: $0.contentRange)) }
    }

    private static func substring(_ source: String, _ range: NSRange?) -> String? {
        range.map { (source as NSString).substring(with: $0) }
    }

    private static func check(_ message: String, _ condition: @autoclosure () throws -> Bool) {
        do {
            if try condition() { return }
        } catch {
            print("FAIL: \(message) (\(error))")
            failures += 1
            return
        }
        print("FAIL: \(message)")
        failures += 1
    }
}

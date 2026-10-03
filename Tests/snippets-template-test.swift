// Standalone contract tests for the real snippet template engine and its placeholders.

import Foundation

@main
@MainActor
struct SnippetTemplateTests {
    static var failures = 0
    static var passes = 0

    static func main() async throws {
        testTemplateExpansion()
        testDynamicPlaceholders()
        testTemplateEncodingAndSelectionAlias()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func testTemplateExpansion() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let now = calendar.date(
            from: DateComponents(
                year: 2026, month: 7, day: 24, hour: 13, minute: 5))!
        let context = SnippetTemplateEngine.ExpansionContext(
            clipboard: "{date} 📋",
            selection: "{cursor} selected",
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone)

        let dateValues = record(
            "/tmp/date-values.md",
            Snippet(name: "Date Values", text: "{date}|{time}"))
        let expandedDateValues = SnippetTemplateEngine.expand(
            dateValues,
            snippets: [dateValues],
            context: context)
        check(
            "default date and time tokens use the injected locale, calendar, and time zone",
            expandedDateValues.text == "Jul 24, 2026|1:05\u{202F}PM")

        let values = record(
            "/tmp/values.md",
            Snippet(
                name: "Values",
                text:
                    "C:{clipboard}|S:{selection}|D:{date format=\"yyyy-MM-dd HH:mm\"}|{argument name=\"First\"}|{argument}|{argument name=\"First\"}"
            ))
        let missing = SnippetTemplateEngine.expand(values, snippets: [values], context: context)
        check(
            "missing arguments are unique and ordered by appearance",
            missing.missingArguments.map(\.name) == ["First", "Argument"])
        check(
            "missing argument tokens stay visible until values are supplied",
            missing.text.hasSuffix("{argument name=\"First\"}|{argument}|{argument name=\"First\"}"))

        let expandedValues = SnippetTemplateEngine.expand(
            values,
            snippets: [values],
            context: context,
            userArguments: ["First": "{clipboard}", "Argument": "{cursor}"])
        check(
            "clipboard, selection, and arguments insert token-shaped text literally",
            expandedValues.text
                == "C:{date} 📋|S:{cursor} selected|D:2026-07-24 13:05|{clipboard}|{cursor}|{clipboard}")
        check(
            "injected cursor-shaped text does not set cursor position",
            expandedValues.cursorOffsetFromEnd == nil)
        check("all supplied arguments clear the missing list", expandedValues.missingArguments.isEmpty)

        let literalBraces = record(
            "/tmp/literal-braces.md",
            Snippet(name: "Literal Braces", text: "{\"generated\":\"{date}\"}|struct { value: {time} }"))
        let literalBraceResult = SnippetTemplateEngine.expand(
            literalBraces,
            snippets: [literalBraces],
            context: context)
        check(
            "literal JSON and code braces do not mask nested valid tokens",
            literalBraceResult.text == "{\"generated\":\"Jul 24, 2026\"}|struct { value: 1:05\u{202F}PM }")

        let promptContextSnippet = record(
            "/tmp/prompt-context.md",
            Snippet(
                name: "Prompt Context",
                text: "{clipboard}|{selection}|{date format=\"HH:mm\"}|{argument name=\"Value\"}"))
        let beforePrompt = SnippetTemplateEngine.expand(
            promptContextSnippet,
            snippets: [promptContextSnippet],
            context: context)
        let afterPrompt = SnippetTemplateEngine.expand(
            promptContextSnippet,
            snippets: [promptContextSnippet],
            context: context,
            userArguments: ["Value": "Done"])
        check(
            "argument prompts reuse the captured expansion context",
            beforePrompt.text.replacingOccurrences(
                of: "{argument name=\"Value\"}",
                with: "Done") == afterPrompt.text)

        let duplicateZ = record("/tmp/z-child.md", Snippet(name: "Child", text: "Z"))
        let duplicateA = record("/tmp/a-child.md", Snippet(name: "Child", text: "A", keyword: "!CHILD"))
        let keywordTarget = record("/tmp/keyword.md", Snippet(name: "Other", text: "K", keyword: "!Key"))
        let references = record(
            "/tmp/references.md",
            Snippet(name: "References", text: "{snippet:cHiLd}|{snippet:!kEy}|{snippet:missing}"))
        let referenced = SnippetTemplateEngine.expand(
            references,
            snippets: [duplicateZ, keywordTarget, references, duplicateA],
            context: context)
        check(
            "duplicate name references resolve by stable path identity",
            referenced.text == "A|K|{snippet:missing}")

        let disabledChild = record(
            "/tmp/disabled-child.md",
            Snippet(name: "Disabled", text: "Secret", keyword: "!disabled", isEnabled: false))
        let disabledReferences = record(
            "/tmp/disabled-references.md",
            Snippet(name: "Disabled References", text: "{snippet:Disabled}|{snippet:!disabled}"))
        let disabledResult = SnippetTemplateEngine.expand(
            disabledReferences,
            snippets: [disabledChild, disabledReferences],
            context: context)
        check(
            "a disabled snippet cannot be expanded by name or keyword reference",
            disabledResult.text == "{snippet:Disabled}|{snippet:!disabled}")

        let cursorChild = record(
            "/tmp/cursor-child.md",
            Snippet(name: "Cursor Child", text: "👨‍👩‍👧‍👦{cursor}é{cursor}"))
        let cursorRoot = record(
            "/tmp/cursor-root.md",
            Snippet(name: "Cursor Root", text: "🙂{snippet:Cursor Child}終{cursor}"))
        let cursorResult = SnippetTemplateEngine.expand(
            cursorRoot,
            snippets: [cursorRoot, cursorChild],
            context: context)
        check("all cursor tokens are removed from final text", cursorResult.text == "🙂👨‍👩‍👧‍👦é終")
        check("first final cursor includes nested cursors", cursorResult.cursorOffsetFromEnd == 2)

        let nestedArguments = record(
            "/tmp/nested-arguments.md",
            Snippet(name: "Nested Arguments", text: "{argument name=\"Nested\"}|{argument name=\"Root\"}"))
        let argumentRoot = record(
            "/tmp/argument-root.md",
            Snippet(
                name: "Argument Root",
                text: "{argument name=\"Root\"}|{snippet:Nested Arguments}|{argument name=\"Last\"}"))
        let argumentResult = SnippetTemplateEngine.expand(
            argumentRoot,
            snippets: [argumentRoot, nestedArguments],
            context: context)
        check(
            "nested arguments follow final appearance order",
            argumentResult.missingArguments.map(\.name) == ["Root", "Nested", "Last"])

        let cycleA = record("/tmp/cycle-a.md", Snippet(name: "A", text: "{snippet:B}"))
        let cycleB = record("/tmp/cycle-b.md", Snippet(name: "B", text: "{snippet:A}"))
        let cycleResult = SnippetTemplateEngine.expand(cycleA, snippets: [cycleA, cycleB], context: context)
        check(
            "cycles are detected with stable record IDs and remain visible", cycleResult.text == "{snippet:A}"
        )

        let depthRecords = (0...6).map { index in
            record(
                "/tmp/depth-\(index).md",
                Snippet(name: "S\(index)", text: index == 6 ? "End" : "{snippet:S\(index + 1)}"))
        }
        let depthResult = SnippetTemplateEngine.expand(
            depthRecords[0],
            snippets: depthRecords,
            context: context)
        check("reference depth limit leaves the unexpanded token visible", depthResult.text == "{snippet:S6}")
    }

    /// Every token, parameter and modifier, against injected clock, locale and UUIDs.
    private static func testDynamicPlaceholders() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let now = calendar.date(
            from: DateComponents(
                year: 2026, month: 7, day: 24, hour: 13, minute: 5))!
        let uuids = UUIDSequence()
        let context = SnippetTemplateEngine.ExpansionContext(
            clipboardHistory: ["  newest  ", "older", "oldest"],
            selection: "picked",
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone,
            makeUUID: { uuids.next() })

        func expand(
            _ text: String, arguments: [String: String] = [:]
        )
            -> SnippetTemplateEngine
            .ExpansionResult
        {
            let subject = record("/tmp/placeholders.md", Snippet(name: "Subject", text: text))
            return SnippetTemplateEngine.expand(
                subject, snippets: [subject], context: context, userArguments: arguments)
        }

        // New date/time tokens.
        check(
            "datetime combines the date and time styles",
            expand("{datetime}").text == "Jul 24, 2026 at 1:05\u{202F}PM")
        check("day renders the weekday name", expand("{day}").text == "Friday")

        // Offsets: signed, multi-unit, and every documented unit.
        check(
            "a single signed offset shifts the date",
            expand("{date offset=\"+1d\"}").text == "Jul 25, 2026")
        check("offsets accept a bare unquoted value", expand("{day offset=-3d}").text == "Tuesday")
        check(
            "multiple offsets apply in order",
            expand("{date offset=\"+2y +5M\"}").text == "Dec 24, 2028")
        check(
            "minute and hour offsets shift the time",
            expand("{time offset=\"+3h +30m\"}").text == "4:35\u{202F}PM")
        check(
            "an unknown offset unit leaves the token literal",
            expand("{date offset=\"+1w\"}").text == "{date offset=\"+1w\"}")
        check(
            "an offset without an amount leaves the token literal",
            expand("{date offset=\"d\"}").text == "{date offset=\"d\"}")

        // Locale and format.
        check(
            "locale overrides the context locale",
            expand("{date locale=\"fr-FR\"}").text == "24 juil. 2026")
        check(
            "format and locale together are rejected as ambiguous",
            expand("{date format=\"yyyy\" locale=\"fr-FR\"}").text
                == "{date format=\"yyyy\" locale=\"fr-FR\"}")
        check(
            "format still applies with an offset",
            expand("{date offset=\"-1d\" format=\"yyyy-MM-dd\"}").text == "2026-07-23")
        check(
            "a bare format needs no quotes",
            expand("{date format=yyyy-MM-dd}").text == "2026-07-24")
        check(
            "a bare format keeps its spaces",
            expand("{date format=MMMM d, yyyy}").text == "July 24, 2026")
        check(
            "a bare value ends at the next parameter",
            expand("{date format=MMM d offset=+1d}").text == "Jul 25")
        check(
            "a bare value trailing another parameter keeps its spaces",
            expand("{date offset=+1d format=MMM d}").text == "Jul 25")
        check(
            "a bare format with no value leaves the token literal",
            expand("{date format=}").text == "{date format=}")

        // UUID comes from the injected source, once per token.
        check("each uuid token draws a fresh value", expand("{uuid}|{uuid}").text == "uuid-1|uuid-2")

        // Clipboard history.
        check(
            "clipboard offset zero is the current clipboard",
            expand("{clipboard}").text == "  newest  ")
        check(
            "clipboard offset reaches back through history",
            expand("{clipboard offset=1}|{clipboard offset=2}").text == "older|oldest")
        check(
            "a clipboard offset past the end expands to nothing",
            expand("{clipboard offset=9}").text.isEmpty)
        check(
            "a negative clipboard offset leaves the token literal",
            expand("{clipboard offset=-1}").text == "{clipboard offset=-1}")

        // Modifier pipeline.
        check(
            "uppercase and lowercase modifiers apply",
            expand("{selection | uppercase}|{selection | lowercase}").text == "PICKED|picked")
        check("trim strips surrounding whitespace", expand("{clipboard | trim}").text == "newest")
        check(
            "modifiers chain left to right",
            expand("{clipboard | trim | uppercase}").text == "NEWEST")
        check(
            "percent-encode escapes everything outside the unreserved set",
            expand("{argument name=\"U\" | percent-encode}", arguments: ["U": "a b/c?d&e=f~g-h"]).text
                == "a%20b%2Fc%3Fd%26e%3Df~g-h")
        check(
            "json-stringify escapes without adding quotes",
            expand("{argument name=\"J\" | json-stringify}", arguments: ["J": "a\"b\\c\nd"]).text
                == "a\\\"b\\\\c\\nd")
        check(
            "raw is accepted and changes nothing",
            expand("{clipboard | raw}").text == "  newest  ")
        check(
            "an unknown modifier leaves the token literal",
            expand("{clipboard | shout}").text == "{clipboard | shout}")
        check(
            "a modifier on a structural token leaves it literal",
            expand("{cursor | uppercase}").text == "{cursor | uppercase}")
        check(
            "a pipe inside a quoted value is not a modifier separator",
            expand("{date format=\"yyyy|MM\"}").text == "2026|07")

        // Arguments: defaults and options.
        let defaulted = expand("{argument name=\"Tone\" default=\"happy\"}")
        check(
            "an argument default expands without prompting",
            defaulted.text == "happy" && defaulted.missingArguments.isEmpty)
        check(
            "a supplied value beats the default",
            expand("{argument name=\"Tone\" default=\"happy\"}", arguments: ["Tone": "sad"]).text
                == "sad")
        let optioned = expand("{argument name=\"Tone\" options=\"happy, sad, professional\"}")
        check(
            "options travel with the missing argument",
            optioned.missingArguments == [
                .init(name: "Tone", options: ["happy", "sad", "professional"])
            ])
        check(
            "an empty options list leaves the token literal",
            expand("{argument name=\"Tone\" options=\", \"}").text
                == "{argument name=\"Tone\" options=\", \"}")

        // What the header's argument fields are built from, without expanding anything else.
        check(
            "declared arguments are listed in written order, once each",
            SnippetTemplateEngine.declaredArguments(
                in: "{argument name=\"Repo\"}/{argument name=\"Branch\"}?q={argument name=\"Repo\"}"
            ).map(\.name) == ["Repo", "Branch"])
        check(
            "an argument that answers itself is never asked for",
            SnippetTemplateEngine.declaredArguments(
                in: "{argument name=\"Tone\" default=\"happy\"}"
            ).isEmpty)
        check(
            "options travel with a declared argument as they do with a missing one",
            SnippetTemplateEngine.declaredArguments(
                in: "{argument name=\"Tone\" options=\"happy, sad\"}")
                == [.init(name: "Tone", options: ["happy", "sad"])])
        check(
            "a template that reads only the clipboard declares no arguments",
            SnippetTemplateEngine.declaredArguments(in: "https://x.dev/?q={clipboard}").isEmpty)

        // Raycast's snippet spelling resolves like Tinycast's.
        let child = record("/tmp/ph-child.md", Snippet(name: "Child", text: "nested"))
        let byName = record("/tmp/ph-name.md", Snippet(name: "ByName", text: "{snippet name=\"Child\"}"))
        let byColon = record("/tmp/ph-colon.md", Snippet(name: "ByColon", text: "{snippet:Child}"))
        let pool = [child, byName, byColon]
        check(
            "snippet name= resolves identically to snippet:",
            SnippetTemplateEngine.expand(byName, snippets: pool, context: context).text == "nested"
                && SnippetTemplateEngine.expand(byColon, snippets: pool, context: context).text
                    == "nested"
        )
        let disabledChild = record(
            "/tmp/ph-disabled.md", Snippet(name: "Off", text: "secret", isEnabled: false))
        let referencesDisabled = record(
            "/tmp/ph-ref-off.md", Snippet(name: "Ref", text: "{snippet name=\"Off\"}"))
        check(
            "snippet name= cannot reach a disabled snippet",
            SnippetTemplateEngine.expand(
                referencesDisabled,
                snippets: [disabledChild, referencesDisabled],
                context: context
            ).text == "{snippet name=\"Off\"}")

        // Malformed tokens stay literal rather than vanishing.
        check("an unknown placeholder stays literal", expand("{weather}").text == "{weather}")
        check(
            "an unknown parameter leaves the token literal",
            expand("{date style=\"long\"}").text == "{date style=\"long\"}")
        check(
            "a duplicated parameter leaves the token literal",
            expand("{date offset=\"+1d\" offset=\"+2d\"}").text
                == "{date offset=\"+1d\" offset=\"+2d\"}")
        check(
            "an unterminated quote leaves the token literal",
            expand("{date format=\"yyyy}").text == "{date format=\"yyyy}")
        check(
            "a parameter on a token that takes none leaves it literal",
            expand("{uuid offset=1}").text == "{uuid offset=1}")
        check(
            "an empty clipboard history expands the clipboard to nothing",
            SnippetTemplateEngine.expand(
                record("/tmp/ph-empty.md", Snippet(name: "E", text: "[{clipboard}]")),
                snippets: [],
                context: SnippetTemplateEngine.ExpansionContext(
                    clipboardHistory: [],
                    selection: "",
                    now: now,
                    calendar: calendar,
                    locale: Locale(identifier: "en_US_POSIX"),
                    timeZone: timeZone)
            ).text == "[]")
    }

    /// Shared with Quicklinks: bare strings, encoding, and Raycast's `{selectedText}`.
    private static func testTemplateEncodingAndSelectionAlias() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let context = SnippetTemplateEngine.ExpansionContext(
            clipboardHistory: ["a b&c"],
            selection: "a b&c",
            now: calendar.date(from: DateComponents(year: 2026, month: 7, day: 24))!,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timeZone)

        func expand(
            _ text: String,
            encoding: SnippetTemplateEngine.ValueEncoding = .none,
            arguments: [String: String] = [:]
        ) -> SnippetTemplateEngine.ExpansionResult {
            SnippetTemplateEngine.expand(
                text: text, context: context, userArguments: arguments, encoding: encoding)
        }

        // The text entry point.
        check(
            "a bare template expands without a snippet record",
            expand("q={clipboard}").text == "q=a b&c")
        check(
            "a snippet reference has nothing to resolve against and stays literal",
            expand("{snippet:Child}").text == "{snippet:Child}")
        check(
            "missing arguments are reported from the text entry point too",
            expand("{argument name=\"Repository\"}").missingArguments
                == [.init(name: "Repository", options: [])])

        // Percent encoding of produced values.
        check(
            "percent encoding escapes a value substituted into a URL",
            expand("https://x.com/?q={clipboard}", encoding: .percentEncoding).text
                == "https://x.com/?q=a%20b%26c")
        check(
            "the literal parts of the template are never encoded",
            expand("https://x.com/a b?q={selection}", encoding: .percentEncoding).text
                == "https://x.com/a b?q=a%20b%26c")
        check(
            "encoding runs after the pipeline, so uppercase cannot rewrite the hex",
            expand("{clipboard | uppercase}", encoding: .percentEncoding).text == "A%20B%26C")
        check(
            "raw opts a value out of automatic encoding",
            expand("{clipboard | raw}", encoding: .percentEncoding).text == "a b&c")
        check(
            "an explicit percent-encode is not applied twice",
            expand("{clipboard | percent-encode}", encoding: .percentEncoding).text
                == "a%20b%26c")
        check(
            "encoding reaches every value-producing token",
            expand("{argument name=\"A\"}", encoding: .percentEncoding, arguments: ["A": "x y"]).text
                == "x%20y")
        check(
            "snippets ask for no encoding, so their expansion is unchanged",
            expand("{clipboard}").text == "a b&c")

        // {selectedText} is an accepted spelling of {selection}.
        check(
            "selectedText resolves to the selection",
            expand("{selectedText}").text == expand("{selection}").text)
        check(
            "the alias is case-insensitive like every other token name",
            expand("{SelectedText}").text == "a b&c")
        check(
            "the alias takes the same modifier pipeline",
            expand("{selectedText | trim | uppercase}").text == "A B&C")
        check(
            "the alias is encoded like the canonical spelling",
            expand("{selectedText}", encoding: .percentEncoding).text == "a%20b%26c")
        check(
            "the alias rejects parameters, exactly as selection does",
            expand("{selectedText offset=1}").text == "{selectedText offset=1}")
        let aliasSnippet = record(
            "/tmp/alias.md", Snippet(name: "Alias", text: "[{selectedText}]"))
        check(
            "a snippet may use the alias too — it is not quicklink-only",
            SnippetTemplateEngine.expand(aliasSnippet, snippets: [], context: context).text
                == "[a b&c]")

        // usesSelection drives the selection-fallback setting.
        check(
            "usesSelection sees both spellings",
            SnippetTemplateEngine.usesSelection("a {selection} b")
                && SnippetTemplateEngine.usesSelection("a {selectedText} b"))
        check(
            "usesSelection is false for a template that reads no selection",
            !SnippetTemplateEngine.usesSelection("{clipboard} {date}"))
        check(
            "usesSelection parses rather than searches, so a malformed token does not count",
            !SnippetTemplateEngine.usesSelection("{selection offset=1}"))

        // {query} is Raycast's spelling of {argument}.
        check(
            "query resolves as an argument named Argument",
            expand("{query}", arguments: ["Argument": "hi"]).text == "hi")
        check(
            "the query alias is case-insensitive like every other token name",
            expand("{Query}", arguments: ["Argument": "hi"]).text == "hi")
        check(
            "the query alias keeps named parameters",
            expand("{query name=\"Keyword\"}", arguments: ["Keyword": "x"]).text == "x")
        check(
            "a parameter named query is still an argument, not the alias",
            expand("{argument name=\"query\"}", arguments: ["query": "kept"]).text == "kept")
    }

    private static func record(_ path: String, _ snippet: Snippet) -> StoredSnippet {
        let source = SnippetMarkdownSerializer.serialize(snippet)
        return StoredSnippet(
            fileURL: URL(fileURLWithPath: path),
            snippet: snippet,
            sourceRevision: SnippetSourceRevision(content: source))
    }

    private static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
            passes += 1
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }
}

/// Deterministic `{uuid}` source; the lock is why it is `@unchecked Sendable`.
private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return "uuid-\(count)"
    }
}

// Standalone contract tests for text delivery, the pasteboard lease and the keyword listener.

import AppKit
import Foundation

@main
@MainActor
struct SnippetDeliveryTests {
    static var failures = 0
    static var passes = 0

    static func main() async throws {
        // The in-process delivery tier drives a real text view, which needs AppKit awake.
        _ = NSApplication.shared
        try await testDeliveryQueueAndPasteboard()
        await testCopySelectionFallback()
        testKeywordPolicy()
        testKeywordLifecycle()
        await testKeywordListenerLifecycle()
        testOwnEditorInjection()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func testCopySelectionFallback() async {
        let injector = TextInjector(clipboardManager: ClipboardManager(), settings: AppSettings())
        let backing = NSPasteboard(name: .init("tinycast-copy-tests-\(UUID().uuidString)"))
        defer { backing.releaseGlobally() }
        let pasteboard = StubPasteboard(backing: backing)

        func seed(_ text: String) {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            backing.clearContents()
            _ = backing.writeObjects([item])
        }

        seed("Something the reader copied earlier")
        let unchanged = await injector.copySelection(from: nil, pasteboard: pasteboard)
        check("a copy that never lands returns nothing, not the stale clipboard", unchanged == nil)
        check(
            "the reader's clipboard survives a failed copy",
            backing.string(forType: .string) == "Something the reader copied earlier")

        seed("Original")
        let writer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            let item = NSPasteboardItem()
            item.setString("the selection", forType: .string)
            backing.clearContents()
            _ = backing.writeObjects([item])
        }
        let copied = await injector.copySelection(from: nil, pasteboard: pasteboard)
        _ = await writer.result
        check("a copy that lands is read back: \(copied ?? "nil")", copied == "the selection")
        check(
            "the reader's clipboard is restored afterwards",
            backing.string(forType: .string) == "Original")
    }

    /// Our panels never activate, so the frontmost app is not where the typist's caret is.
    private static func testOwnEditorInjection() {
        let editor = HarnessEditor(frame: NSRect(x: 0, y: 0, width: 320, height: 120))

        // The tap sees the keystroke first, so the view is a character behind at match time.
        editor.string = "!si"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        check(
            "a document shorter than the keyword reads as pending, not absent",
            editor.keywordReplacementState(expectedKeyword: "!sig", keywordLength: 4) == .pending)

        editor.string = "Regards, !si"
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        check(
            "the same stale view behind existing text reads as a mismatch, not a lag",
            editor.keywordReplacementState(expectedKeyword: "!sig", keywordLength: 4) == .rejected)

        editor.string = "Regards, !sig"
        editor.setSelectedRange(NSRange(location: 13, length: 0))
        check(
            "the keyword resolves once AppKit has delivered the keystroke",
            editor.keywordReplacementState(expectedKeyword: "!sig", keywordLength: 4)
                == .matched(NSRange(location: 9, length: 4)))

        editor.inject(InjectedText("Ada Lovelace"), over: NSRange(location: 9, length: 4))
        check(
            "a converged keyword is replaced in place",
            editor.string == "Regards, Ada Lovelace")
        check(
            "the caret lands after the text the snippet inserted",
            editor.selectedRange() == NSRange(location: 21, length: 0))

        editor.string = "Regards, !xyz"
        editor.setSelectedRange(NSRange(location: 13, length: 0))
        check(
            "enough text that is not the keyword is a mismatch, never a wait",
            editor.keywordReplacementState(expectedKeyword: "!sig", keywordLength: 4) == .rejected)

        editor.string = "wrap me"
        editor.setSelectedRange(NSRange(location: 0, length: 7))
        check(
            "a zero-length keyword takes the selection as its replacement range",
            editor.keywordReplacementState(expectedKeyword: nil, keywordLength: 0)
                == .matched(NSRange(location: 0, length: 7)))

        editor.inject(
            InjectedText("<b></b>", cursorOffsetFromEnd: 4), over: NSRange(location: 0, length: 7))
        check(
            "the selection is replaced and the caret honours the template's cursor offset",
            editor.string == "<b></b>" && editor.selectedRange() == NSRange(location: 3, length: 0))

        check(
            "the caret offset counts UTF-16 units, not characters",
            InjectedText("\u{1F1F3}\u{1F1F1} done", cursorOffsetFromEnd: 5).caretPrefixLength == 4)
    }

    private static func testDeliveryQueueAndPasteboard() async throws {
        let queue = DeliveryQueue()
        var order: [String] = []
        queue.enqueue(isAutomatic: false) {
            order.append("first-start")
            try? await Task.sleep(for: .milliseconds(30))
            order.append("first-end")
        }
        queue.enqueue(isAutomatic: false) {
            order.append("second")
        }
        await queue.drain()
        check(
            "interactive deliveries are retained and serialized",
            order == ["first-start", "first-end", "second"] && queue.isIdle)

        var automaticRan = false
        queue.enqueue(isAutomatic: false) {
            try? await Task.sleep(for: .milliseconds(30))
        }
        queue.enqueue(isAutomatic: true) {
            automaticRan = true
        }
        queue.cancelAutomatic()
        await queue.drain()
        check("automatic cancellation cannot run a queued stale delivery", !automaticRan)

        var completionCount = 0
        var failureCount = 0
        let completion = DeliveryCompletion(
            onDelivered: { completionCount += 1 }, onFailed: { failureCount += 1 })
        completion.confirm()
        completion.confirm()
        completion.settle()
        check(
            "delivery completion invokes its callback exactly once after confirmation",
            completion.isConfirmed && completionCount == 1 && failureCount == 0)

        var unconfirmedFailures = 0
        let unconfirmed = DeliveryCompletion(onFailed: { unconfirmedFailures += 1 })
        unconfirmed.settle()
        unconfirmed.settle()
        unconfirmed.confirm()
        check(
            "a delivery that returned early reports failure exactly once and stays unconfirmed",
            !unconfirmed.isConfirmed && unconfirmedFailures == 1)

        check(
            "unavailable AX text attributes use the event delivery fallback",
            AccessibilityReplacement.unavailable.fallsBackToEvents)
        check(
            "a rejected AX keyword replacement fails closed instead of deleting by events",
            !AccessibilityReplacement.rejected.fallsBackToEvents)

        check(
            "an AX keyword one character behind the event stream remains pending",
            TextReplacementPolicy.keywordState(
                value: "!tcaxprob",
                selectedRange: NSRange(location: 9, length: 0),
                keyword: "!tcaxprobe") == .pending)
        check(
            "a converged AX keyword resolves to its exact replacement range",
            TextReplacementPolicy.keywordState(
                value: "prefix !tcaxprobe",
                selectedRange: NSRange(location: 17, length: 0),
                keyword: "!tcaxprobe") == .matched(NSRange(location: 7, length: 10)))
        check(
            "an AX state with enough text but the wrong suffix is a genuine rejection",
            TextReplacementPolicy.keywordState(
                value: "prefix !tcaxwrong",
                selectedRange: NSRange(location: 17, length: 0),
                keyword: "!tcaxprobe") == .rejected)
        check(
            "an empty editor AX snapshot remains pending instead of becoming a false mismatch",
            TextReplacementPolicy.keywordState(
                value: "",
                selectedRange: NSRange(location: 0, length: 0),
                keyword: "!tcaxprobe") == .pending)
        check(
            "a non-empty selection is a mismatch rather than a lagging caret",
            TextReplacementPolicy.keywordState(
                value: "prefix !tcaxprobe",
                selectedRange: NSRange(location: 7, length: 10),
                keyword: "!tcaxprobe") == .rejected)
        check(
            "AX replacement confirmation requires the observable text to actually change",
            TextReplacementPolicy.confirmsReplacement(
                originalValue: "!tcprobe",
                replacementRange: NSRange(location: 0, length: 8),
                insertedText: "PROBE_OK",
                observedValue: "PROBE_OK"))
        check(
            "an AX setter success with unchanged text is not accepted as delivery",
            !TextReplacementPolicy.confirmsReplacement(
                originalValue: "!tcprobe",
                replacementRange: NSRange(location: 0, length: 8),
                insertedText: "PROBE_OK",
                observedValue: "!tcprobe"))
        check(
            "an AX write that lands somewhere unexpected is not accepted as delivery",
            !TextReplacementPolicy.confirmsReplacement(
                originalValue: "keep !tcprobe",
                replacementRange: NSRange(location: 5, length: 8),
                insertedText: "PROBE_OK",
                observedValue: "PROBE_OK !tcprobe"))
        check(
            "an unreadable value after the write is not accepted as delivery",
            !TextReplacementPolicy.confirmsReplacement(
                originalValue: "!tcprobe",
                replacementRange: NSRange(location: 0, length: 8),
                insertedText: "PROBE_OK",
                observedValue: nil))

        check(
            "a Unicode keystroke never carries more than Blink's four-unit cap",
            UnicodeTypingChunk.split(String(repeating: "a", count: 30))
                .allSatisfy { $0.count <= UnicodeTypingChunk.maxUTF16Units })
        check(
            "chunked Unicode keystrokes reassemble into the original text",
            UnicodeTypingChunk.split("Fix this sentence, 雪が降る 👨‍👩‍👧 — done.")
                .flatMap { $0 } == Array("Fix this sentence, 雪が降る 👨‍👩‍👧 — done.".utf16))
        check(
            "a surrogate pair is never split across two keystrokes",
            UnicodeTypingChunk.split("ab👩🏽‍🚀").allSatisfy { chunk in
                String(decoding: chunk, as: UTF16.self).unicodeScalars.allSatisfy { $0.value != 0xFFFD }
            })
        check("empty text produces no keystrokes", UnicodeTypingChunk.split("").isEmpty)
        check(
            "unreadable AX state accepts a posted paste after the conservative delay",
            PasteConfirmationPolicy.acceptsUnconfirmedDelivery(
                attempt: 15,
                hadPreviousState: true,
                readStateAfterPaste: false))
        check(
            "readable unchanged AX state is not treated as a confirmed paste",
            !PasteConfirmationPolicy.acceptsUnconfirmedDelivery(
                attempt: 79,
                hadPreviousState: true,
                readStateAfterPaste: true))

        let backingPasteboard = NSPasteboard(
            name: .init("tinycast-snippets-tests-\(UUID().uuidString)"))
        let pasteboard = StubPasteboard(backing: backingPasteboard)
        defer { backingPasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("com.example.custom")
        let firstItem = NSPasteboardItem()
        firstItem.setString("Original", forType: .string)
        firstItem.setData(Data([0, 1, 2, 3]), forType: customType)
        let secondType = NSPasteboard.PasteboardType("com.example.second")
        let secondItem = NSPasteboardItem()
        secondItem.setData(Data([4, 5, 6]), forType: secondType)
        check(
            "pasteboard fixture writes multiple items and types",
            pasteboard.replaceObjects([firstItem, secondItem]))

        let lease = TemporaryPasteboardLease.begin(
            text: "Temporary",
            pasteboard: pasteboard)
        check(
            "the lent pasteboard carries the text and no representation of the original",
            lease?.isOwned == true
                && pasteboard.string(forType: .string) == "Temporary"
                && pasteboard.pasteboardItems?.count == 1
                && pasteboard.pasteboardItems?[0].data(forType: customType) == nil
                && pasteboard.pasteboardItems?[0].data(forType: secondType) == nil
        )
        let restoreResult = lease?.restoreIfOwned()
        let restoredItems = pasteboard.pasteboardItems
        check(
            "pasteboard restoration preserves every item, type, and payload",
            restoreResult != nil
                && restoredItems?.count == 2
                && restoredItems?[0].string(forType: .string) == "Original"
                && restoredItems?[0].data(forType: customType) == Data([0, 1, 2, 3])
                && restoredItems?[1].data(forType: secondType) == Data([4, 5, 6]))
        check(
            "pasteboard restoration leaves no Tinycast marker on the restored clipboard",
            restoredItems?.allSatisfy {
                !$0.types.contains(ClipboardManager.internalType)
            } == true)

        pasteboard.writeFailuresRemaining = 1
        var recoveredMutationCount: Int?
        let failedLease = TemporaryPasteboardLease.begin(
            text: "Temporary failure",
            pasteboard: pasteboard,
            onMutation: { recoveredMutationCount = $0 })
        check(
            "a failed temporary write restores the original clipboard before falling back",
            failedLease == nil
                && pasteboard.string(forType: .string) == "Original"
                && pasteboard.pasteboardItems?.count == 2
                && recoveredMutationCount == pasteboard.changeCount)

        let supersededLease = TemporaryPasteboardLease.begin(
            text: "Temporary again",
            pasteboard: pasteboard)
        let newerItem = NSPasteboardItem()
        newerItem.setString("Newer copy", forType: .string)
        _ = pasteboard.replaceObjects([newerItem])
        check(
            "pasteboard restoration never overwrites a newer copy",
            supersededLease?.restoreIfOwned() == .superseded
                && pasteboard.string(forType: .string) == "Newer copy")

        _ = pasteboard.replaceObjects([])
        let emptyLease = TemporaryPasteboardLease.begin(
            text: "Temporary from empty",
            pasteboard: pasteboard)
        check(
            "an empty clipboard still lends a temporary string to paste",
            emptyLease?.isOwned == true
                && pasteboard.string(forType: .string) == "Temporary from empty")
        check(
            "restoring a borrowed empty clipboard leaves it empty again",
            emptyLease?.restoreIfOwned() != nil
                && pasteboard.pasteboardItems?.isEmpty != false)

        let imageOnlyItem = NSPasteboardItem()
        imageOnlyItem.setData(Data([9, 8, 7]), forType: .png)
        _ = pasteboard.replaceObjects([imageOnlyItem])
        let imageLease = TemporaryPasteboardLease.begin(
            text: "Temporary over image",
            pasteboard: pasteboard)
        check(
            "a non-text clipboard still lends a temporary string to paste",
            imageLease?.isOwned == true
                && pasteboard.string(forType: .string) == "Temporary over image")
        check(
            "restoring a borrowed image clipboard returns the original payload",
            imageLease?.restoreIfOwned() != nil
                && pasteboard.pasteboardItems?.count == 1
                && pasteboard.data(forType: .png) == Data([9, 8, 7])
                && pasteboard.string(forType: .string) == nil)
    }

    private static func testKeywordPolicy() {
        let base = Date(timeIntervalSince1970: 1_000)
        var policy = SnippetKeywordPolicy(keywords: [
            .init(snippetID: "/tmp/short.md", value: "bc"),
            .init(snippetID: "/tmp/long.md", value: "abc"),
            .init(snippetID: "/tmp/z-duplicate.md", value: "!dup"),
            .init(snippetID: "/tmp/a-duplicate.md", value: "!DUP"),
            .init(snippetID: "/tmp/trimmed.md", value: "  !trim  "),
            .init(
                snippetID: "/tmp/too-long.md",
                value: String(repeating: "x", count: SnippetKeywordPolicy.maximumBufferLength + 1))
        ])

        let longest = policy.process(.text("abc"), at: base)
        check("keyword matching prefers the longest suffix", longest?.snippetID == "/tmp/long.md")
        let duplicate = policy.process(.text("!DuP"), at: base.addingTimeInterval(1))
        check(
            "duplicate keywords resolve by stable snippet identity",
            duplicate?.snippetID == "/tmp/a-duplicate.md")
        let trimmed = policy.process(.text("!trim"), at: base.addingTimeInterval(1.5))
        check(
            "keyword matching trims surrounding whitespace and deletes only the trigger",
            trimmed
                == .init(
                    snippetID: "/tmp/trimmed.md",
                    keyword: "!trim",
                    deletionCount: 5))
        check(
            "keywords longer than the buffer cap are excluded",
            !policy.keywords.contains { $0.snippetID == "/tmp/too-long.md" })

        let syntheticInput = SnippetKeywordPolicy.classifyInput(
            text: "p",
            isSynthetic: true,
            secureEventInputEnabled: false,
            isFlagsChanged: false,
            isKeyDown: true,
            hasCommandOrControl: false,
            isResetKey: false,
            isDeleteBackward: false)
        check("synthetic Tinycast events are classified as ignored", syntheticInput == .ignored)
        _ = policy.process(.text("!du"), at: base.addingTimeInterval(2))
        _ = policy.process(syntheticInput, at: base.addingTimeInterval(2.5))
        let afterSynthetic = policy.process(.text("p"), at: base.addingTimeInterval(3))
        check(
            "ignored synthetic events do not alter the keyword buffer",
            afterSynthetic?.snippetID == "/tmp/a-duplicate.md")

        let secureInput = SnippetKeywordPolicy.classifyInput(
            text: "x",
            isSynthetic: false,
            secureEventInputEnabled: true,
            isFlagsChanged: false,
            isKeyDown: true,
            hasCommandOrControl: false,
            isResetKey: false,
            isDeleteBackward: false)
        check("Secure Event Input classifies keystrokes as a buffer reset", secureInput == .reset)
        let modifiedInput = SnippetKeywordPolicy.classifyInput(
            text: "x",
            isSynthetic: false,
            secureEventInputEnabled: false,
            isFlagsChanged: false,
            isKeyDown: true,
            hasCommandOrControl: true,
            isResetKey: false,
            isDeleteBackward: false)
        check("command and control shortcuts classify as buffer resets", modifiedInput == .reset)

        let shiftTransition = SnippetKeywordPolicy.classifyInput(
            text: nil,
            isSynthetic: false,
            secureEventInputEnabled: false,
            isFlagsChanged: true,
            isKeyDown: false,
            hasCommandOrControl: false,
            isResetKey: false,
            isDeleteBackward: false)
        var shiftedKeywordPolicy = SnippetKeywordPolicy(keywords: [
            .init(snippetID: "/tmp/notes.md", value: "!notes")
        ])
        _ = shiftedKeywordPolicy.process(.text("!"), at: base.addingTimeInterval(10))
        _ = shiftedKeywordPolicy.process(shiftTransition, at: base.addingTimeInterval(10.1))
        let shiftedKeywordMatch = shiftedKeywordPolicy.process(
            .text("notes"),
            at: base.addingTimeInterval(10.2))
        check(
            "Shift and Option flag transitions preserve modifier-produced keywords",
            shiftTransition == .ignored
                && shiftedKeywordMatch?.snippetID == "/tmp/notes.md")

        _ = policy.process(.text("a"), at: base.addingTimeInterval(40))
        let afterTimeout = policy.process(.text("bc"), at: base.addingTimeInterval(56))
        check(
            "keyword buffer resets after the inactivity timeout", afterTimeout?.snippetID == "/tmp/short.md")

        _ = policy.process(.text("!dux"), at: base.addingTimeInterval(60))
        _ = policy.process(.deleteBackward, at: base.addingTimeInterval(61))
        let afterDelete = policy.process(.text("p"), at: base.addingTimeInterval(62))
        check(
            "backspace updates the buffered suffix deterministically",
            afterDelete?.snippetID == "/tmp/a-duplicate.md")

        _ = policy.process(
            .text(String(repeating: "x", count: SnippetKeywordPolicy.maximumBufferLength + 20)),
            at: base.addingTimeInterval(70))
        check("keyword buffer is capped", policy.buffer.count == SnippetKeywordPolicy.maximumBufferLength)
        _ = policy.process(.reset, at: base.addingTimeInterval(71))
        check("navigation and session resets clear the complete buffer", policy.buffer.isEmpty)

    }

    private static func testKeywordLifecycle() {
        typealias Lifecycle = SnippetKeywordLifecyclePolicy

        let consentOff = Lifecycle.decide(
            isRequested: false,
            isSessionActive: true,
            hasAccessibility: true,
            tapState: .absent)
        check(
            "listener remains off without consent",
            consentOff == .init(status: .off, tapAction: .none))

        let stopWithTap = Lifecycle.decide(
            isRequested: false,
            isSessionActive: true,
            hasAccessibility: true,
            tapState: .active)
        check(
            "stop tears down an installed tap synchronously",
            stopWithTap == .init(status: .off, tapAction: .tearDown))

        let waiting = Lifecycle.decide(
            isRequested: true,
            isSessionActive: true,
            hasAccessibility: false,
            tapState: .absent)
        check(
            "consent waits without the Accessibility grant and does not install a tap",
            waiting == .init(status: .needsAccessibility, tapAction: .none))

        let grantsArrived = Lifecycle.decide(
            isRequested: true,
            isSessionActive: true,
            hasAccessibility: true,
            tapState: .absent)
        check(
            "a later health check installs the tap after the grant arrives",
            grantsArrived == .init(status: .needsAccessibility, tapAction: .install))

        let active = Lifecycle.decide(
            isRequested: true,
            isSessionActive: true,
            hasAccessibility: true,
            tapState: .active)
        check(
            "listener reports active only with the grant and a live tap",
            active == .init(status: .active, tapAction: .none))

        let revoked = Lifecycle.decide(
            isRequested: true,
            isSessionActive: true,
            hasAccessibility: false,
            tapState: .active)
        check(
            "permission revocation moves to waiting and tears down the tap",
            revoked == .init(status: .needsAccessibility, tapAction: .tearDown))

        let disabled = Lifecycle.decide(
            isRequested: true,
            isSessionActive: true,
            hasAccessibility: true,
            tapState: .disabled)
        check(
            "a disabled tap is re-enabled before the listener can be active",
            disabled == .init(status: .needsAccessibility, tapAction: .reenable))

        let inactiveSession = Lifecycle.decide(
            isRequested: true,
            isSessionActive: false,
            hasAccessibility: true,
            tapState: .active)
        check(
            "session resignation tears down the tap and leaves consent waiting",
            inactiveSession == .init(status: .needsAccessibility, tapAction: .tearDown))

        let rapidOff = Lifecycle.decide(
            isRequested: false,
            isSessionActive: true,
            hasAccessibility: true,
            tapState: .active)
        let rapidOn = Lifecycle.decide(
            isRequested: true,
            isSessionActive: true,
            hasAccessibility: true,
            tapState: .absent)
        check(
            "rapid off then on cannot preserve a stale active tap",
            rapidOff.tapAction == .tearDown
                && rapidOff.status == .off
                && rapidOn.tapAction == .install
                && rapidOn.status == .needsAccessibility)
    }

    private static func testKeywordListenerLifecycle() async {
        let permissions = FakeSnippetPermissions()
        let tap = FakeSnippetKeywordTapController()
        tap.installFailuresRemaining = 1
        let listener = SnippetKeywordListener(
            tapController: tap,
            accessibilityTrusted: { permissions.accessibility },
            secureEventInputEnabled: { false },
            now: { Date(timeIntervalSince1970: 1_000) },
            syntheticEventTag: 123,
            logsTapFailures: false)
        var activityCount = 0

        listener.start(onUserActivity: { activityCount += 1 }, onMatch: { _, _, _, _ in })
        check(
            "real listener waits without permissions and does not install",
            listener.status == .needsAccessibility && tap.installCount == 0)

        permissions.accessibility = true
        listener.healthCheck()
        check(
            "real listener keeps a failed tap installation retryable",
            listener.status == .needsAccessibility
                && tap.installCount == 1
                && tap.state == .absent)
        listener.healthCheck()
        check(
            "real listener applies installation after grants arrive",
            listener.status == .active
                && tap.installCount == 2
                && tap.state == .active)

        listener.processEvent(
            typeRaw: CGEventType.keyDown.rawValue,
            keyCode: 0,
            flagsRaw: 0,
            text: "x",
            eventUserData: 0,
            secureEventInputEnabled: false)
        listener.processEvent(
            typeRaw: CGEventType.keyDown.rawValue,
            keyCode: 0,
            flagsRaw: 0,
            text: "x",
            eventUserData: 123,
            secureEventInputEnabled: false)
        check(
            "real user input invalidates pending automatic delivery while Tinycast events do not",
            activityCount == 1)

        listener.isPromptingForArguments = true
        for text in ["a", "b", "c", "d", "\r"] {
            listener.processEvent(
                typeRaw: CGEventType.keyDown.rawValue,
                keyCode: 0,
                flagsRaw: 0,
                text: text,
                eventUserData: 0,
                secureEventInputEnabled: false)
        }
        listener.userActivity()
        check("argument typing and Expand clicks preserve pending delivery", activityCount == 1)
        listener.isPromptingForArguments = false
        listener.userActivity()
        check("user activity cancels delivery again after the prompt", activityCount == 2)

        listener.start(onUserActivity: { activityCount += 1 }, onMatch: { _, _, _, _ in })
        check(
            "real listener repeated start does not install a second tap",
            listener.status == .active && tap.installCount == 2)

        let snippet = record(
            "/tmp/argument-listener.md", Snippet(name: "Test", text: "{argument}", keyword: "#test"))
        listener.update([snippet])
        var matches = 0
        listener.start(onUserActivity: { activityCount += 1 }, onMatch: { _, _, _, _ in matches += 1 })
        func typeKeyword() {
            for character in "#test" {
                listener.processEvent(
                    typeRaw: CGEventType.keyDown.rawValue, keyCode: 0, flagsRaw: 0,
                    text: String(character), eventUserData: 0, secureEventInputEnabled: false)
            }
        }
        typeKeyword()
        check("keyword callbacks run after the triggering event returns", matches == 0)
        try? await Task.sleep(for: .milliseconds(10))
        check("a queued keyword match is delivered", matches == 1)
        typeKeyword()
        listener.userActivity()
        try? await Task.sleep(for: .milliseconds(10))
        check("activity cancels a match before its callback runs", matches == 1)
        listener.isPromptingForArguments = true
        typeKeyword()
        listener.isPromptingForArguments = false
        try? await Task.sleep(for: .milliseconds(10))
        check("argument text cannot trigger nested expansion", matches == 1)

        tap.state = .disabled
        listener.healthCheck()
        check(
            "real listener applies tap re-enable and returns active",
            listener.status == .active
                && tap.reenableCount == 1
                && tap.state == .active)

        tap.reenableSucceeds = false
        tap.state = .disabled
        listener.healthCheck()
        check(
            "real listener recreates a tap when re-enable fails",
            listener.status == .active
                && tap.tearDownCount >= 1
                && tap.installCount == 3)
        tap.reenableSucceeds = true

        permissions.accessibility = false
        listener.healthCheck()
        check(
            "real listener tears down synchronously on permission revocation",
            listener.status == .needsAccessibility && tap.state == .absent)

        permissions.accessibility = true
        listener.healthCheck()
        check(
            "real listener reinstalls after permission regrant",
            listener.status == .active && tap.state == .active)

        listener.stop()
        check(
            "real listener stop is authoritative",
            listener.status == .off && tap.state == .absent)
        listener.start(onUserActivity: { activityCount += 1 }, onMatch: { _, _, _, _ in })
        listener.stop()
        check(
            "real listener rapid on and off leaves no tap",
            listener.status == .off && tap.state == .absent)
    }

    private static func record(_ path: String, _ snippet: Snippet) -> StoredSnippet {
        let source = SnippetMarkdownSerializer.serialize(snippet)
        return StoredSnippet(
            fileURL: URL(fileURLWithPath: path),
            snippet: snippet,
            sourceRevision: SnippetSourceRevision(content: source))
    }

    // The same budget a fixed sleep spent, but a prompt watcher costs milliseconds of it.
    private static func settle(
        within timeout: Duration = .milliseconds(500),
        until condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
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

@MainActor
private final class StubPasteboard: PasteboardAccess {
    let backing: NSPasteboard
    var writeFailuresRemaining = 0

    init(backing: NSPasteboard) {
        self.backing = backing
    }

    var changeCount: Int { backing.changeCount }
    var pasteboardItems: [NSPasteboardItem]? { backing.pasteboardItems }

    @discardableResult
    func clearContents() -> Int {
        backing.clearContents()
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        if writeFailuresRemaining > 0 {
            writeFailuresRemaining -= 1
            return false
        }
        return backing.writeObjects(objects)
    }

    func replaceObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        clearContents()
        return objects.isEmpty || writeObjects(objects)
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        backing.string(forType: type)
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        backing.data(forType: type)
    }
}

@MainActor
final class ClipboardManager {
    static let internalType = NSPasteboard.PasteboardType("com.tinycast.internal")
    func prepareForTinycastPasteboardMutation() {}
    func synchronizeAfterTinycastPasteboardMutation(changeCount: Int) {}
}

@MainActor
final class AppSettings {
    var snippetsEnabled = false
}

enum Permissions {
    static func ensureAccessibility() -> Bool { false }
    static func isAccessibilityTrusted() -> Bool { false }
}

enum Paster {
    static let tinycastEventTag: Int64 = 0x54494E59
    @MainActor static func postCommandV(toPid pid: pid_t? = nil) {}
    @MainActor static func postCommandC(toPid pid: pid_t? = nil) {}
}

@MainActor
private final class FakeSnippetPermissions {
    var accessibility = false
}

@MainActor
private final class FakeSnippetKeywordTapController: SnippetKeywordTapControlling {
    var state: SnippetKeywordLifecyclePolicy.TapState = .absent
    var installFailuresRemaining = 0
    var reenableSucceeds = true
    private(set) var installCount = 0
    private(set) var reenableCount = 0
    private(set) var tearDownCount = 0

    func install(listener: SnippetKeywordListener) -> Bool {
        installCount += 1
        if installFailuresRemaining > 0 {
            installFailuresRemaining -= 1
            state = .absent
            return false
        }
        state = .active
        return true
    }

    func reenable() -> Bool {
        reenableCount += 1
        state = reenableSucceeds ? .active : .disabled
        return reenableSucceeds
    }

    func tearDown() {
        tearDownCount += 1
        state = .absent
    }
}

/// Stands in for `NoteTextView`: the conformance is the whole opt-in.
private final class HarnessEditor: NSTextView, InjectableTextView {}

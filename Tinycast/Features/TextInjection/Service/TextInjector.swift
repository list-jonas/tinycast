import AppKit
import Carbon.HIToolbox

@MainActor
final class TextInjector {
    typealias AutomaticGeneration = UInt

    private let clipboardManager: ClipboardManager
    private let settings: AppSettings
    private let deliveryQueue = DeliveryQueue()
    private var automaticGeneration: AutomaticGeneration = 0
    private var activePasteboardLease: TemporaryPasteboardLease?

    /// A renderer, or AppKit handing us our own keystroke, converges in single-digit milliseconds.
    private static let convergenceAttempts = 8
    private static let convergenceInterval = Duration.milliseconds(5)
    /// A copy lands well inside a second; past that the app was never going to answer.
    private static let copyPollAttempts = 40
    private static let copyPollInterval = Duration.milliseconds(25)

    init(clipboardManager: ClipboardManager, settings: AppSettings) {
        self.clipboardManager = clipboardManager
        self.settings = settings
    }

    /// A paste is still in flight, or we still hold the pasteboard it borrowed.
    var isDelivering: Bool { !deliveryQueue.isIdle || activePasteboardLease != nil }

    func prepareInteractiveExpansion(target: InjectionTarget?) -> Bool {
        if let editor = target?.ownEditor { return editor.isEditable }
        guard targetAcceptsInjection(target?.externalApp), Permissions.ensureAccessibility() else {
            target?.restoreFocus()
            return false
        }
        return true
    }

    func beginAutomaticExpansion(target: InjectionTarget?) -> AutomaticGeneration? {
        cancelAutomaticExpansion()
        guard expansionIsAllowed(generation: automaticGeneration, target: target) else { return nil }
        return automaticGeneration
    }

    func cancelAutomaticExpansion(target: InjectionTarget? = nil) {
        automaticGeneration &+= 1
        deliveryQueue.cancelAutomatic()
        target?.restoreFocus()
    }

    func prepareForTermination() {
        automaticGeneration &+= 1
        deliveryQueue.cancelAll()
        finishPendingPasteboardOwnership()
    }

    func cancelArgumentPrompt(automaticGeneration: AutomaticGeneration?, target: InjectionTarget?) {
        if automaticGeneration != nil {
            cancelAutomaticExpansion(target: target)
        } else {
            target?.restoreFocus()
        }
    }

    func captureExpansionContext(
        target: InjectionTarget?, clipboardHistory: [String]
    ) -> SnippetTemplateEngine.ExpansionContext {
        let selection: String
        switch target {
        case .ownEditor(let editor): selection = editor.injectableSelection
        case .external(let app) where Permissions.isAccessibilityTrusted():
            selection = AccessibilityText.selection(in: app) ?? ""
        default: selection = ""
        }
        return SnippetTemplateEngine.ExpansionContext(
            clipboardHistory: clipboardHistory, selection: selection, now: Date(),
            calendar: Calendar.current, locale: Locale.current, timeZone: .current)
    }

    /// The caller must know there *is* a selection: a zero-length one inserts at the caret instead.
    func replaceSelection(
        with text: String,
        in targetApp: NSRunningApplication?,
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor () -> Void = {}
    ) {
        deliver(
            InjectedText(text), target: targetApp.map(InjectionTarget.external),
            expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil, onDelivered: onDelivered, onFailed: onFailed)
    }

    /// A `changeCount` that never moves means nothing was selected, not that the old clipboard won.
    func copySelection(from targetApp: NSRunningApplication?) async -> String? {
        await deliveryQueue.drain()
        guard finishPendingPasteboardOwnership(),
            await activateAndWaitForTarget(targetApp, automaticGeneration: nil),
            canPost(nil, to: targetApp, prompting: true)
        else { return nil }
        return await copySelection(from: targetApp, pasteboard: NSPasteboard.general)
    }

    /// Split for the harness, which drives a stub pasteboard rather than another app.
    func copySelection(
        from targetApp: NSRunningApplication?, pasteboard: any PasteboardAccess
    ) async -> String? {
        clipboardManager.prepareForTinycastPasteboardMutation()
        guard let original = PasteboardSnapshot(pasteboard: pasteboard) else { return nil }
        defer {
            if let items = original.pasteboardItems() {
                pasteboard.clearContents()
                if pasteboard.writeObjects(items) {
                    clipboardManager.synchronizeAfterTinycastPasteboardMutation(
                        changeCount: pasteboard.changeCount)
                }
            }
        }

        Paster.postCommandC(toPid: targetApp?.processIdentifier)
        for _ in 0..<Self.copyPollAttempts {
            guard await wait(for: Self.copyPollInterval) else { return nil }
            guard pasteboard.changeCount != original.changeCount else { continue }
            guard let data = PasteboardSnapshot(pasteboard: pasteboard)?.firstStringData
            else { return nil }
            return String(bytes: data, encoding: .utf8)
        }
        return nil
    }

    func deliver(
        _ injected: InjectedText,
        target: InjectionTarget?,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?,
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor () -> Void = {}
    ) {
        let targetApp = target?.externalApp
        activate(targetApp)
        if let automaticGeneration {
            guard expansionIsAllowed(generation: automaticGeneration, target: target) else { return }
        } else {
            guard prepareInteractiveExpansion(target: target) else {
                onFailed()
                return
            }
        }

        let request = Request(
            injected: injected, expectedKeyword: expectedKeyword,
            keywordLength: keywordLength, generation: automaticGeneration)
        deliveryQueue.enqueue(isAutomatic: automaticGeneration != nil) { [weak self] in
            guard let self else { return }
            let completion = DeliveryCompletion(onDelivered: onDelivered, onFailed: onFailed)
            defer { completion.settle() }
            if let editor = target?.ownEditor {
                await self.deliverInProcess(request, into: editor, completion: completion)
            } else {
                await self.deliverExternally(request, to: targetApp, completion: completion)
            }
        }
    }

    private struct Request {
        let injected: InjectedText
        let expectedKeyword: String?
        let keywordLength: Int
        let generation: AutomaticGeneration?
    }

    // MARK: - Gates

    /// A hotkey's target comes from `frontmostApplication`, which can be Tinycast itself.
    private func targetAcceptsInjection(_ targetApp: NSRunningApplication?) -> Bool {
        guard let targetApp else { return false }
        return !targetApp.isTerminated
            && targetApp.bundleIdentifier != Bundle.main.bundleIdentifier
            && !IsSecureEventInputEnabled()
    }

    private func automaticExpansionIsAllowed(
        generation: AutomaticGeneration, targetApp: NSRunningApplication?
    ) -> Bool {
        generation == automaticGeneration && settings.snippetsEnabled
            && Permissions.isAccessibilityTrusted() && targetAcceptsInjection(targetApp)
    }

    /// In process there is nothing to grant, activate or post: our own view is the whole contract.
    private func expansionIsAllowed(generation: AutomaticGeneration, target: InjectionTarget?) -> Bool {
        switch target {
        case .ownEditor(let editor):
            generation == automaticGeneration && settings.snippetsEnabled && editor.isEditable
        case .external(let app):
            automaticExpansionIsAllowed(generation: generation, targetApp: app)
        case nil:
            false
        }
    }

    private func isFrontmost(_ app: NSRunningApplication) -> Bool {
        app.isActive
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// Re-checked before every post, so a target that went away or went secure stops delivery.
    private func canPost(
        _ generation: AutomaticGeneration?, to targetApp: NSRunningApplication?,
        prompting: Bool = false
    ) -> Bool {
        guard let targetApp, isFrontmost(targetApp) else { return false }
        if let generation {
            return automaticExpansionIsAllowed(generation: generation, targetApp: targetApp)
        }
        guard targetAcceptsInjection(targetApp) else { return false }
        return prompting ? Permissions.ensureAccessibility() : Permissions.isAccessibilityTrusted()
    }

    private func activate(_ targetApp: NSRunningApplication?) {
        guard targetApp?.isTerminated == false else { return }
        targetApp?.activate()
    }

    private func activateAndWaitForTarget(
        _ targetApp: NSRunningApplication?, automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        guard let targetApp else { return false }
        activate(targetApp)
        for _ in 0..<50 {
            if isFrontmost(targetApp) { return true }
            if let automaticGeneration,
                !automaticExpansionIsAllowed(generation: automaticGeneration, targetApp: targetApp)
            {
                return false
            }
            guard await wait(for: .milliseconds(20)) else { return false }
        }
        return false
    }

    private func wait(for duration: Duration) async -> Bool {
        (try? await Task.sleep(for: duration)) != nil && !Task.isCancelled
    }

    // MARK: - In process

    /// Needs no grant, activation or pasteboard, but the keyword still converges on Rule 2.
    private func deliverInProcess(
        _ request: Request, into editor: any InjectableTextView, completion: DeliveryCompletion
    ) async {
        for _ in 0..<Self.convergenceAttempts {
            // The tap runs ahead of AppKit, so looking before the wait reads a stale view as a miss.
            if request.keywordLength > 0 {
                guard await wait(for: Self.convergenceInterval) else { return }
            }
            if let generation = request.generation {
                guard expansionIsAllowed(generation: generation, target: .ownEditor(editor))
                else { return }
            } else if !editor.isEditable {
                return
            }
            switch editor.keywordReplacementState(
                expectedKeyword: request.expectedKeyword, keywordLength: request.keywordLength)
            {
            case .matched(let range):
                editor.inject(request.injected, over: range)
                completion.confirm()
                return
            case .rejected:
                return
            case .pending:
                continue
            }
        }
    }

    // MARK: - Another app

    private func deliverExternally(
        _ request: Request, to targetApp: NSRunningApplication?, completion: DeliveryCompletion
    ) async {
        let generation = request.generation
        guard finishPendingPasteboardOwnership(),
            await activateAndWaitForTarget(targetApp, automaticGeneration: generation),
            canPost(generation, to: targetApp, prompting: true)
        else { return }

        switch await replaceUsingAccessibility(request, targetApp: targetApp) {
        case .delivered:
            completion.confirm()
            return
        case .rejected:
            return
        case .unavailable:
            break
        }
        guard await deliverUsingEvents(request, targetApp: targetApp) else { return }

        let offset = request.injected.cursorOffsetFromEnd ?? 0
        for index in 0..<max(offset, 0) {
            guard canPost(generation, to: targetApp),
                let arrow = SyntheticKeystroke.key(code: CGKeyCode(kVK_LeftArrow))
            else { return }
            SyntheticKeystroke.post(arrow, to: targetApp)
            if index < offset - 1, !(await wait(for: .milliseconds(8))) { return }
        }
        completion.confirm()
    }

    private func deliverUsingEvents(_ request: Request, targetApp: NSRunningApplication?) async -> Bool {
        let text = request.injected.text
        let generation = request.generation
        let isShortSingleLine = text.count <= 100 && !text.contains("\n") && !text.contains("\r")
        guard !isShortSingleLine, let lease = beginTemporaryPasteboardLease(text) else {
            guard let insertionEvents = SyntheticKeystroke.unicode(text),
                let deletionEvents = SyntheticKeystroke.deletions(request.keywordLength),
                canPost(generation, to: targetApp),
                await post(deletionEvents, to: targetApp, generation: generation),
                await waitAfterKeywordDeletion(request.keywordLength),
                await post(insertionEvents, to: targetApp, generation: generation)
            else { return false }
            return await wait(for: .milliseconds(100))
        }
        activePasteboardLease = lease
        defer { finish(lease) }

        guard let deletionEvents = SyntheticKeystroke.deletions(request.keywordLength),
            await wait(for: .milliseconds(80)),
            lease.isOwned,
            canPost(generation, to: targetApp),
            await post(deletionEvents, to: targetApp, generation: generation),
            await waitAfterKeywordDeletion(request.keywordLength),
            lease.isOwned,
            canPost(generation, to: targetApp)
        else { return false }

        let stateBeforePaste = targetApp.flatMap(AccessibilityTextField.focused)?.state
        Paster.postCommandV(toPid: targetApp?.processIdentifier)
        return await waitForPasteConfirmation(
            previousState: stateBeforePaste, lease: lease, targetApp: targetApp, generation: generation)
    }

    /// Each group is one keystroke, spaced so a target that stops accepting them halts the rest.
    private func post(
        _ events: [SyntheticKeystroke.Pair], to targetApp: NSRunningApplication?,
        generation: AutomaticGeneration?
    ) async -> Bool {
        for index in events.indices {
            guard canPost(generation, to: targetApp) else { return false }
            SyntheticKeystroke.post(events[index], to: targetApp)
            if index < events.count - 1, !(await wait(for: .milliseconds(8))) { return false }
        }
        return true
    }

    private func waitAfterKeywordDeletion(_ keywordLength: Int) async -> Bool {
        if keywordLength == 0 { return true }
        return await wait(for: .milliseconds(40))
    }

    private func waitForPasteConfirmation(
        previousState: AccessibilityTextField.State?,
        lease: TemporaryPasteboardLease,
        targetApp: NSRunningApplication?,
        generation: AutomaticGeneration?
    ) async -> Bool {
        var readStateAfterPaste = false
        for attempt in 0..<80 {
            guard lease.isOwned, canPost(generation, to: targetApp) else { return false }
            if let previousState,
                let currentState = targetApp.flatMap(AccessibilityTextField.focused)?.state
            {
                readStateAfterPaste = true
                if currentState != previousState { return true }
            }
            if PasteConfirmationPolicy.acceptsUnconfirmedDelivery(
                attempt: attempt, hadPreviousState: previousState != nil,
                readStateAfterPaste: readStateAfterPaste)
            {
                return true
            }
            guard await wait(for: .milliseconds(25)) else { return false }
        }
        return false
    }

    // MARK: - Pasteboard

    private func beginTemporaryPasteboardLease(_ text: String) -> TemporaryPasteboardLease? {
        clipboardManager.prepareForTinycastPasteboardMutation()
        return TemporaryPasteboardLease.begin(
            text: text, pasteboard: NSPasteboard.general,
            onMutation: clipboardManager.synchronizeAfterTinycastPasteboardMutation(changeCount:))
    }

    @discardableResult
    private func finishPendingPasteboardOwnership() -> Bool {
        guard let lease = activePasteboardLease else { return true }
        for _ in 0..<3 where lease.isOwned { finish(lease) }
        return !lease.isOwned
    }

    private func finish(_ lease: TemporaryPasteboardLease) {
        switch lease.restoreIfOwned() {
        case .restored(let changeCount):
            // Keeps the poller from recording the restored original as a second copy.
            clipboardManager.synchronizeAfterTinycastPasteboardMutation(changeCount: changeCount)
        case .superseded:
            break
        case .failed:
            // Still ours, so leave `activePasteboardLease` in place for the retry below.
            if lease.isOwned { return }
        }
        if activePasteboardLease === lease { activePasteboardLease = nil }
    }

    // MARK: - Accessibility tier

    /// Rule 1: a renderer surface answers about its own model, so it is never written to over AX.
    private func replaceUsingAccessibility(
        _ request: Request, targetApp: NSRunningApplication?
    ) async -> AccessibilityReplacement {
        guard let targetApp else { return .unavailable }
        let target: AccessibilityTarget
        switch await accessibilityTarget(in: targetApp, request: request) {
        case .ready(let ready): target = ready
        case .rejected: return .rejected
        case .pending, .unavailable: return .unavailable
        }
        let field = target.field
        let text = request.injected.text
        guard field.select(target.replacementRange) else { return .unavailable }
        guard field.replaceSelection(with: text) else {
            field.select(target.originalRange)
            return .unavailable
        }
        let observed = field.value
        guard
            TextReplacementPolicy.confirmsReplacement(
                originalValue: target.value, replacementRange: target.replacementRange,
                insertedText: text, observedValue: observed)
        else {
            field.select(target.originalRange)
            // An untouched value is a tier that did nothing; anything else moved text we cannot name.
            return observed == target.value ? .unavailable : .rejected
        }
        field.select(
            NSRange(
                location: target.replacementRange.location + request.injected.caretPrefixLength,
                length: 0))
        return .delivered
    }

    private struct AccessibilityTarget {
        let field: AccessibilityTextField
        let value: String
        let originalRange: NSRange
        let replacementRange: NSRange
    }

    private enum AccessibilityTargetState {
        case ready(AccessibilityTarget)
        case pending
        case unavailable
        case rejected
    }

    /// Rule 2: a renderer applies the keystroke before it says so, so a short lag is not a mismatch.
    private func accessibilityTarget(
        in targetApp: NSRunningApplication, request: Request
    ) async -> AccessibilityTargetState {
        for attempt in 0..<Self.convergenceAttempts {
            let state = inspectAccessibilityTarget(in: targetApp, request: request)
            guard case .pending = state else { return state }
            guard attempt < Self.convergenceAttempts - 1,
                request.generation != nil,
                canPost(request.generation, to: targetApp),
                await wait(for: Self.convergenceInterval)
            else { return .unavailable }
        }
        return .unavailable
    }

    private func inspectAccessibilityTarget(
        in targetApp: NSRunningApplication, request: Request
    ) -> AccessibilityTargetState {
        guard let field = AccessibilityTextField.focused(in: targetApp),
            field.acceptsReplacement,
            let state = field.state
        else { return .unavailable }
        let value = state.value
        let originalRange = state.selectedRange
        func ready(_ range: NSRange) -> AccessibilityTargetState {
            .ready(
                AccessibilityTarget(
                    field: field, value: value, originalRange: originalRange, replacementRange: range))
        }

        guard request.keywordLength > 0 else {
            // Offsets its own value cannot address are a broken tier, not proof the document moved.
            return Range(originalRange, in: value) == nil ? .unavailable : ready(originalRange)
        }
        guard let keyword = request.expectedKeyword, keyword.count == request.keywordLength
        else { return .rejected }
        switch TextReplacementPolicy.keywordState(
            value: value, selectedRange: originalRange, keyword: keyword)
        {
        case .matched(let replacementRange): return ready(replacementRange)
        case .pending: return .pending
        case .rejected: return .rejected
        }
    }
}

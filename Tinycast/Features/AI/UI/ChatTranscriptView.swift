import AppKit
import SwiftUI

/// Find in chat's matches and the one to show; the transcript marks them and scrolls to it.
struct ChatFindHighlight: Equatable {
    let query: String
    let matches: Set<UUID>
    let current: ChatFindOccurrence?
}

/// Where a transcript is drawn: the palette's scroll grammar is measured against its own bars.
enum ChatSurface {
    case palette
    case window
}

struct ChatTranscriptView: View {

    @Environment(\.metrics) private var metrics
    let messages: [ChatMessage]
    let status: String?
    let usage: AIUsage?
    let surface: ChatSurface
    /// Offered on the last reply once it has finished; nil where a surface has no room for it.
    var onRegenerate: (() -> Void)?
    /// Answers with one of the last reply's choices; nil leaves them unshown.
    var onChoose: ((String) -> Void)?
    var find: ChatFindHighlight?
    /// Cleared when the reader scrolls up, so a streaming reply stops dragging them back down.
    @State private var followsTail = true

    /// Below this a backward move is momentum settling, not the reader asking for the wheel.
    private static let deliberateScroll: CGFloat = 2

    /// Where the reader sits and whether that is the end; a growing reply moves the end on its own.
    private struct ScrollMark: Equatable {
        var offset: CGFloat
        var atEnd: Bool
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: every anchored jump and the end test measure an estimated height
                VStack(spacing: metrics.spacing.xl) {
                    ForEach(messages) { message in
                        let isLast = message.id == messages.last?.id
                        ChatMessageView(
                            message: message,
                            status: isLast ? status : nil,
                            onRegenerate: isLast && message.role == .assistant
                                ? onRegenerate : nil,
                            // Only the latest reply's choices still answer anything.
                            onChoose: isLast && message.state == .complete ? onChoose : nil
                        )
                        .equatable()
                        .environment(\.chatTextHighlight, highlight(for: message.id))
                        .id(message.id)
                    }
                    if let total = usage?.totalTokens {
                        Text("\(total.formatted()) tokens")
                            .font(metrics.typography.rowTrailing)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Color.clear
                        .frame(height: metrics.spacing.xxs)
                        .id("ai-transcript-tail")
                }
                .padding(.horizontal, metrics.spacing.xxl)
                .padding(.top, metrics.spacing.xl)
                .padding(
                    .bottom,
                    surface == .palette ? metrics.spacing.chatTranscriptBottom : metrics.spacing.xl
                )
                .lineSpacing(metrics.spacing.chatLine)
                // A window can be any width; a line of prose past this stops being readable.
                .frame(maxWidth: surface == .window ? Theme.Size.aiChatReadingWidth : nil)
                .frame(maxWidth: .infinity)
            }
            .modifier(TranscriptScrollChrome(surface: surface))
            // Reopened chats start at the latest message; other anchor roles fight the reader.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollMark.self) { geometry in
                ScrollMark(
                    offset: geometry.contentOffset.y,
                    // The offset rests at `-insetTop`, so the end is that far past offset plus band
                    atEnd: geometry.contentOffset.y + geometry.containerSize.height
                        + geometry.contentInsets.top
                        >= geometry.contentSize.height - metrics.spacing.chatFollowTailSlack)
            } action: { old, new in
                // The offset is the only signal every device gives; the end wins, tested first
                if new.atEnd {
                    followsTail = true
                } else if new.offset < old.offset - Self.deliberateScroll {
                    followsTail = false
                }
            }
            .onChange(of: messages.count) { follow(proxy, always: true) }
            .onChange(of: find?.current) { _, current in
                guard current != nil else { return }
                followsTail = false
                // Next turn: the text holding the match takes its anchor in this same update.
                Task { @MainActor in
                    withAnimation(.easeOut(duration: Theme.Duration.chatFooter)) {
                        proxy.scrollTo(ChatTextHighlight.currentAnchor, anchor: .center)
                    }
                }
            }
            .onChange(of: messages) { follow(proxy, always: false) }
            .onChange(of: usage) { follow(proxy, always: false) }
            .overlay(alignment: .bottom) {
                ResumeFollowingButton {
                    followsTail = true
                    follow(proxy, always: true)
                }
                .padding(.bottom, metrics.spacing.lg)
                .opacity(followsTail ? 0 : 1)
                .allowsHitTesting(!followsTail)
                .animation(.easeOut(duration: Theme.Duration.chatFooter), value: followsTail)
            }
        }
    }

    private func highlight(for id: UUID) -> ChatTextHighlight? {
        guard let find, find.matches.contains(id) else { return nil }
        return ChatTextHighlight(
            query: find.query, current: find.current?.messageID == id ? find.current : nil)
    }

    /// A sent message always comes into view; a growing reply only while the reader is at the end.
    private func follow(_ proxy: ScrollViewProxy, always: Bool) {
        guard always || followsTail else { return }
        proxy.scrollTo("ai-transcript-tail", anchor: .bottom)
    }
}

/// The dissolve and thin bar are tuned to the palette's floating bars; a window scrolls natively.
private struct TranscriptScrollChrome: ViewModifier {
    let surface: ChatSurface

    func body(content: Content) -> some View {
        switch surface {
        case .palette: content.edgeDissolve().thinScrollbar()
        case .window: content
        }
    }
}

/// A fast reply outruns a reader scrolling toward it, so this asks for the tail, not chases it.
private struct ResumeFollowingButton: View {
    @Environment(\.metrics) private var metrics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Jump to Latest", systemImage: "arrow.down")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, metrics.spacing.lg)
                .padding(.vertical, metrics.spacing.sm)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.Colors.border))
        }
        .buttonStyle(.plain)
    }
}

/// Equatable, so a flush redraws only the changed reply; closures compare by presence alone.
private struct ChatMessageView: View, @MainActor Equatable {

    @Environment(\.metrics) private var metrics
    let message: ChatMessage
    let status: String?
    let onRegenerate: (() -> Void)?
    let onChoose: ((String) -> Void)?
    @Environment(\.chatTextHighlight) private var highlight

    @State private var hovered = false

    private typealias Parts = (text: String, choices: [String])

    var body: some View {
        // The fence is the choices' carrier, never prose: it is left out of the text and the copy.
        let parts: Parts = message.role == .assistant ? ChatChoices.split(message.text) : (message.text, [])
        return HStack {
            if message.role == .user { Spacer(minLength: metrics.spacing.xxl) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: metrics.spacing.xxs) {
                content(parts)
                if message.state != .streaming { footer(copying: parts.text) }
            }
            .contentShape(Rectangle())
            .onHover { isHovered in
                if isHovered {
                    withAnimation(.easeOut(duration: Theme.Duration.chatFooter)) {
                        hovered = true
                    }
                } else {
                    hovered = false
                }
            }
            if message.role == .assistant { Spacer(minLength: metrics.spacing.xxl) }
        }
    }

    /// Laid out at rest and only faded in, so a hover cannot reflow the transcript
    private func footer(copying text: String) -> some View {
        HStack(spacing: metrics.spacing.sm) {
            if message.role == .user { timestamp }
            ChatCopyButton(text: text)
            if let onRegenerate { RegenerateButton(action: onRegenerate) }
            if message.role == .assistant { timestamp }
        }
        .opacity(hovered ? 1 : 0)
        // A reply's footer hugs the same `sm` edge as its text.
        .padding(.horizontal, message.role == .user ? metrics.spacing.md : metrics.spacing.sm)
    }

    private var timestamp: some View {
        Text(message.sentAt.formatted(date: .omitted, time: .shortened))
            .font(metrics.typography.keyCap)
            .foregroundStyle(Theme.Colors.textTertiary)
    }

    @ViewBuilder private func content(_ parts: Parts) -> some View {
        if message.text.isEmpty, message.searches.isEmpty, message.toolUses.isEmpty,
            message.reasoning.isEmpty, message.state == .streaming
        {
            HStack(spacing: metrics.spacing.sm) {
                ProgressView().controlSize(.small)
                if let status { Text(status).foregroundStyle(.secondary) }
            }
            .padding(metrics.spacing.md)
        } else {
            bubbleContent(parts)
                .font(metrics.typography.rowTitle)
                .foregroundStyle(message.state == .failed ? Theme.Colors.destructive : .primary)
                .textSelection(.enabled)
                // The user bubble is inset because it carries a fill; a reply clears the chevron
                .padding(.horizontal, message.role == .user ? metrics.spacing.xl : metrics.spacing.sm)
                .padding(.vertical, metrics.spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                        .fill(message.role == .user ? Theme.Colors.controlSurface : Color.clear)
                )
        }
    }

    private func bubbleContent(_ parts: Parts) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: metrics.spacing.sm) {
            if !message.images.isEmpty {
                // Wider than the stack's own rhythm: two 96pt tiles at `sm` read as one blob.
                HStack(spacing: metrics.spacing.xl) {
                    ForEach(message.images, id: \.self) { image in
                        ChatImageThumbnail(image: image, edge: metrics.size.chatImageThumb)
                    }
                }
            }
            if !message.documents.isEmpty {
                HStack(spacing: metrics.spacing.md) {
                    ForEach(message.documents, id: \.self) { document in
                        ChatDocumentChip(document: document)
                    }
                }
            }
            if !message.text.isEmpty || !message.searches.isEmpty || !message.toolUses.isEmpty
                || !message.reasoning.isEmpty
            {
                rendered(parts)
            }
        }
    }

    /// Only a reply is markdown — what the user typed is shown back exactly as they typed it.
    @ViewBuilder private func rendered(_ parts: Parts) -> some View {
        if message.role == .assistant {
            // Read only once the reply is done: a link half-streamed is not a source yet.
            let references = message.state == .streaming ? [] : ChatReferences.extract(from: parts.text)
            let segments = message.segments
            VStack(alignment: .leading, spacing: metrics.spacing.lg) {
                ForEach(Array(segments.enumerated()), id: \.offset) { offset, segment in
                    Group {
                        switch segment {
                        case .text(let text):
                            ChatMarkdownText(
                                blocks: MarkdownBlock.parse(
                                    ChatChoices.split(text).text,
                                    midStream: message.isArriving(segmentAt: offset, of: segments.count)),
                                failed: message.state == .failed)
                        case .search(let search):
                            ChatActivityRow(search: search)
                        case .tools(let uses):
                            ChatToolRun(uses: uses)
                        case .reasoning(let block):
                            ChatReasoningBlock(
                                block: block,
                                isThinking: message.state == .streaming && block.duration == nil)
                        }
                    }
                    .environment(\.chatFindPath, [offset])
                }
                if let onChoose, !parts.choices.isEmpty {
                    ChatSuggestionChips(choices: parts.choices, onChoose: onChoose)
                }
                if !references.isEmpty { ChatSourcesView(references: references) }
            }
            .environment(\.chatCitations, ChatReferences.numbers(for: references))
        } else {
            Text(highlight?.attributed(message.text, leaf: [0]) ?? AttributedString(message.text))
                .findAnchor(highlight, leaf: [0])
        }
    }
}

extension ChatMessageView {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.status == rhs.status
            && (lhs.onRegenerate == nil) == (rhs.onRegenerate == nil)
            && (lhs.onChoose == nil) == (rhs.onChoose == nil)
    }
}

/// The pages a reply linked to, gathered under it the way a cited answer lists its sources.
private struct ChatSourcesView: View {
    @Environment(\.metrics) private var metrics
    let references: [ChatReference]

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Text("Sources")
                .font(metrics.typography.rowTrailing.weight(.semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
            ChatFlowLayout(spacing: metrics.spacing.sm) {
                ForEach(Array(references.enumerated()), id: \.element) { index, reference in
                    ChatSourceChip(index: index + 1, reference: reference)
                }
            }
        }
        .padding(.top, metrics.spacing.xs)
    }
}

private struct ChatSourceChip: View {
    @Environment(\.metrics) private var metrics
    let index: Int
    let reference: ChatReference

    var body: some View {
        Button {
            NSWorkspace.shared.open(reference.url)
        } label: {
            HStack(spacing: metrics.spacing.xs) {
                Text("\(index)")
                    .font(metrics.typography.keyCap)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(reference.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Theme.Size.chatSourceTitle, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if reference.title != reference.host {
                    Text(reference.host)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            .font(metrics.typography.rowTrailing)
            .padding(.horizontal, metrics.spacing.xs)
        }
        .buttonStyle(.glass)
        .help(reference.url.absoluteString)
        .accessibilityLabel("Source \(index): \(reference.title), \(reference.host)")
    }
}

private struct RegenerateButton: View {
    @Environment(\.metrics) private var metrics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: metrics.size.chatMessageAction, height: metrics.size.chatMessageAction)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Regenerate Response")
        .accessibilityLabel("Regenerate Response")
    }
}

/// One stretch of thinking: folded by default, one click from being read, and opened by find.
private struct ChatReasoningBlock: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.chatTextHighlight) private var highlight
    @Environment(\.chatFindPath) private var path
    let block: ChatReasoning
    let isThinking: Bool
    @State private var expanded = false

    private var title: String {
        if isThinking { return "Thinking…" }
        guard let duration = block.duration else { return "Thoughts" }
        return "Thought for \(max(1, Int(duration.rounded())))s"
    }

    /// A match inside a folded block would be found and then invisible, so find unfolds it.
    private var isOpen: Bool {
        expanded
            || highlight.map {
                block.text.range(of: $0.query, options: [.caseInsensitive, .diacriticInsensitive])
                    != nil
            } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Button {
                withAnimation(.easeOut(duration: Theme.Duration.chatFooter)) { expanded.toggle() }
            } label: {
                HStack(spacing: metrics.spacing.xs) {
                    if isThinking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "brain")
                            .symbolRenderingMode(.hierarchical)
                    }
                    Text(title)
                    Image(systemName: "chevron.right")
                        .font(metrics.typography.keyCap)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Hide reasoning" : "Show reasoning")
            if isOpen {
                Text(highlight?.attributed(block.text, leaf: path) ?? AttributedString(block.text))
                    .findAnchor(highlight, leaf: path)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, metrics.spacing.md)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.Colors.border)
                            .frame(width: metrics.size.markdownQuoteBar)
                    }
                    .transition(.opacity)
            }
        }
    }
}

/// A sent document names itself: its bytes went to the model, not into the transcript's prose.
private struct ChatDocumentChip: View {
    @Environment(\.metrics) private var metrics
    let document: AIDocument

    private var isPDF: Bool { document.mimeType == AIAttachmentPolicy.pdfMIMEType }

    var body: some View {
        HStack(spacing: metrics.spacing.xs) {
            Image(systemName: isPDF ? "doc.richtext" : "doc.plaintext")
                .font(metrics.typography.chip)
                .symbolRenderingMode(.hierarchical)
            Text(document.name)
                .font(metrics.typography.chip)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(.horizontal, metrics.spacing.sm)
        .padding(.vertical, metrics.spacing.xxs)
        .background(Capsule().fill(Theme.Colors.controlSurface))
        .accessibilityLabel("Attached file \(document.name)")
    }
}

/// Downsampled off-main to the tile, so a transcript never holds a photo's full-size bitmap.
private struct ChatImageThumbnail: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.displayScale) private var displayScale
    let image: AIImage
    let edge: CGFloat
    @State private var decoded: NSImage?

    var body: some View {
        let key = Key(image: image, pixels: edge * displayScale)
        Group {
            if let decoded {
                Image(nsImage: decoded).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .frame(width: edge, height: edge)
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous))
        // Interface Size and the display both move the pixel target, so either redraws the tile.
        .task(id: key) {
            let data = key.image.data
            let thumbnail = await Task.detached(priority: .userInitiated) {
                Self.thumbnail(of: data, filling: key.pixels)
            }.value
            guard !Task.isCancelled else { return }
            decoded = thumbnail.map { NSImage(cgImage: $0, size: .zero) } ?? NSImage(data: data)
        }
    }

    private struct Key: Hashable {
        let image: AIImage
        let pixels: CGFloat
    }

    /// The tile is filled, so the short side, not the long one, must reach the pixel size.
    nonisolated private static func thumbnail(of data: Data, filling pixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            min(width, height) > 0
        else { return nil }
        let longest = max(width, height) * min(1, pixels / min(width, height))
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longest.rounded(.up)
            ] as CFDictionary)
    }
}

/// Calls with nothing between them: the one running while live, then a count that opens to each.
private struct ChatToolRun: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let uses: [ChatToolUse]
    @State private var isExpanded = false

    var body: some View {
        if uses.count == 1, let use = uses.first {
            ChatActivityRow(use: use)
        } else {
            VStack(alignment: .leading, spacing: metrics.spacing.sm) {
                if let running = uses.runningCall {
                    ChatActivityRow(use: running)
                } else {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: metrics.spacing.sm) {
                            Image(
                                systemName: uses.failedCount > 0
                                    ? "exclamationmark.triangle" : "wrench.and.screwdriver"
                            )
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(
                                uses.failedCount > 0
                                    ? Theme.Colors.destructive : Theme.Colors.textSecondary)
                            Text(uses.completedLabel)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(metrics.typography.disclosure)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                                .animation(
                                    reduceMotion ? nil : Theme.MenuMotion.chevronAnimation,
                                    value: isExpanded)
                        }
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(uses.completedLabel)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    if isExpanded {
                        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
                            ForEach(uses, id: \.callID) { ChatActivityRow(use: $0) }
                        }
                        .padding(.leading, metrics.spacing.xxl)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.Duration.chatFooter), value: uses)
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.Duration.chatFooter), value: isExpanded)
        }
    }
}

/// A search or tool call inside a reply: a spinner while it runs, then its glyph and what it did.
private struct ChatActivityRow: View {
    @Environment(\.metrics) private var metrics
    /// Nil while running.
    let symbol: String?
    var failed = false
    let label: String
    var labelLineLimit: Int?
    var detail: String?

    init(search: ChatSearch) {
        symbol = search.isComplete ? "globe" : nil
        label = search.isComplete ? "Searched web" : "Searching web"
        detail = search.query?.isEmpty == false ? search.query : nil
    }

    init(use: ChatToolUse) {
        failed = use.state == .failed
        symbol = switch use.state {
        case .running: nil
        case .completed: "wrench.and.screwdriver"
        case .failed: "exclamationmark.triangle"
        }
        label = use.label
        labelLineLimit = 1
    }

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            if let symbol {
                // Sized by the row's own font, not by a symbol point size.
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(failed ? Theme.Colors.destructive : Theme.Colors.textSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(label).lineLimit(labelLineLimit)
            if let detail {
                Text("· \(detail)")
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textSecondary)
        .animation(.easeOut(duration: Theme.Duration.chatFooter), value: symbol)
    }
}

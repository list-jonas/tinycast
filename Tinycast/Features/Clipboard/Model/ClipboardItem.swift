import Foundation

struct ClipboardItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case text, image, file }

    let id: UUID
    let kind: Kind
    /// The copied text, or for a `.file` entry the absolute path — which is what FTS indexes.
    let text: String?
    /// Absolute path on disk; only files under `imagesDir` are ours to delete.
    let imagePath: String?
    let createdAt: Date
    /// Bundle ID of the app frontmost when the copy was captured (see `ClipboardManager.poll`).
    let sourceBundleID: String?
    /// When the entry was pinned; pins lead the list and are exempt from pruning.
    let pinnedAt: Date?

    var isPinned: Bool { pinnedAt != nil }

    /// The referenced path, so no call site re-derives a file entry's meaning from `text`.
    var filePath: String? { kind == .file ? text : nil }

    /// What Paste as Plain Text writes: the text, or a file's path in place of the file.
    var plainText: String? { kind == .image ? nil : text }

    /// Whether Copy Text (⇧⌘T) applies: a captured image, or an image file copied in Finder.
    var offersTextExtraction: Bool {
        switch kind {
        case .image: imagePath != nil
        case .file: filePath.map { ClipboardFileKind.of(path: $0) == .image } ?? false
        case .text: false
        }
    }

    init(text: String, sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: .text, text: text, imagePath: nil, createdAt: Date(),
            sourceBundleID: sourceBundleID)
    }

    init(imagePath: String, createdAt: Date = Date(), sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: .image, text: nil, imagePath: imagePath, createdAt: createdAt,
            sourceBundleID: sourceBundleID)
    }

    /// Referenced where it lies: `imagePath` stays nil, keeping an unowned file from `deleteBlob`.
    init(filePath: String, createdAt: Date = Date(), sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: .file, text: filePath, imagePath: nil, createdAt: createdAt,
            sourceBundleID: sourceBundleID)
    }

    init(
        id: UUID, kind: Kind, text: String?, imagePath: String?, createdAt: Date,
        sourceBundleID: String?, pinnedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imagePath = imagePath
        self.createdAt = createdAt
        self.sourceBundleID = sourceBundleID
        self.pinnedAt = pinnedAt
    }

    /// Copy with the two fields the store rewrites; the pin is always stated outright.
    func with(createdAt: Date? = nil, pinnedAt: Date?) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            createdAt: createdAt ?? self.createdAt, sourceBundleID: sourceBundleID, pinnedAt: pinnedAt)
    }

    /// Case-insensitive substring match: how the store filters without FTS.
    func matches(_ query: String) -> Bool {
        text?.localizedCaseInsensitiveContains(query) ?? false
    }
}

import Foundation

enum RaycastClipboardImport {
    static func parse(
        _ value: Any?, now: () -> Date, fileExists: (String) -> Bool
    ) -> (items: [ClipboardItem], missing: Int) {
        guard let entries = (value as? [String: Any])?["clipboardEntries"] as? [[String: Any]]
        else { return ([], 0) }

        let fractionalParser = ISO8601DateFormatter()
        fractionalParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Built once rather than per entry: a formatter is costly to create.
        let wholeSecondParser = ISO8601DateFormatter()

        var items: [ClipboardItem] = []
        var missing = 0
        for entry in entries {
            let createdAt =
                (entry["createdAt"] as? String).flatMap {
                    fractionalParser.date(from: $0) ?? wholeSecondParser.date(from: $0)
                } ?? now()
            let pinnedAt = isPinned(entry["pinned"]) ? createdAt : nil
            let reps = (entry["items"] as? [[String: Any]] ?? [])
                .flatMap { ($0["representations"] as? [[String: Any]]) ?? [] }

            if let text = reps.first(where: {
                ($0["mimeType"] as? String)?.hasPrefix("text/plain") == true
            })?["content"] as? String, !text.isEmpty {
                items.append(
                    ClipboardItem(
                        id: UUID(), kind: .text, text: text, imagePath: nil, createdAt: createdAt,
                        sourceBundleID: nil, pinnedAt: pinnedAt))
                continue
            }

            if let path = reps.first(where: {
                ($0["mimeType"] as? String)?.hasPrefix("image/") == true
                    && ($0["contentType"] as? String) == "url"
            })?["content"] as? String {
                guard fileExists(path) else {
                    missing += 1
                    continue
                }
                items.append(
                    ClipboardItem(
                        id: UUID(), kind: .image, text: nil, imagePath: path, createdAt: createdAt,
                        sourceBundleID: nil, pinnedAt: pinnedAt))
            }
        }
        return (items, missing)
    }

    private static func isPinned(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return false }
        return number.boolValue
    }
}

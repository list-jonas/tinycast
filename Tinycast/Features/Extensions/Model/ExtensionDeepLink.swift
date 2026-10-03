import Foundation

/// A `raycast://extensions/<owner>/<extension>/<command>` link; `tinycast://` mirrors it.
struct ExtensionDeepLink: Sendable, Equatable {
    let ownerOrAuthor: String?
    let extensionName: String
    let commandName: String
    let arguments: [String: String]
    let fallbackText: String?
    let launchType: ExtensionLaunchType

    /// `owner/ext` first so a scoped manifest wins over a bare slug collision.
    var extensionCandidates: [String] {
        guard let ownerOrAuthor, !ownerOrAuthor.isEmpty else { return [extensionName] }
        return ["\(ownerOrAuthor)/\(extensionName)", extensionName]
    }

    func matches(manifestName: String) -> Bool {
        let lowered = manifestName.lowercased()
        if extensionCandidates.contains(where: { $0.lowercased() == lowered }) { return true }
        return manifestName.split(separator: "/").last?.lowercased() == extensionName.lowercased()
    }

    static func claims(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["raycast", "tinycast", "com.raycast", "raycastinternal"].contains(scheme)
    }

    /// Host and first path segment unify `raycast://extensions/…` and `com.raycast:/extensions/…`.
    static func parse(url: URL) -> ExtensionDeepLink? {
        guard claims(url) else { return nil }
        var segments: [String] = []
        if let host = url.host, !host.isEmpty { segments.append(host) }
        segments += url.pathComponents.filter { $0 != "/" }
        segments = segments.map { $0.removingPercentEncoding ?? $0 }
        guard segments.count >= 3, segments[0].lowercased() == "extensions" else { return nil }
        let body = segments.dropFirst()
        let ownerOrAuthor = body.count > 2 ? body.dropLast(2).joined(separator: "/") : nil
        let (extensionName, commandName) = (body[body.endIndex - 2], body[body.endIndex - 1])
        guard !extensionName.isEmpty, !commandName.isEmpty else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var arguments: [String: String] = [:]
        var fallbackText: String?
        var launchType = ExtensionLaunchType.userInitiated
        for item in items {
            switch item.name.lowercased() {
            case "arguments":
                if let raw = item.value { arguments = parseArguments(raw) }
            case "fallbacktext":
                fallbackText = item.value
            case "launchtype", "launch_type":
                launchType = item.value?.lowercased() == "background" ? .background : .userInitiated
            default:
                break
            }
        }
        return ExtensionDeepLink(
            ownerOrAuthor: ownerOrAuthor, extensionName: extensionName, commandName: commandName,
            arguments: arguments, fallbackText: fallbackText, launchType: launchType)
    }

    /// Raycast sends one URL-encoded JSON object; anything else means no arguments, not a failure.
    nonisolated static func parseArguments(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data),
            let dict = json as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in dict {
            if let string = value as? String {
                out[key] = string
            } else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    out[key] = number.boolValue ? "true" : "false"
                } else {
                    let double = number.doubleValue
                    out[key] = double == double.rounded() && double.magnitude < 1e15
                        ? String(number.int64Value) : String(double)
                }
            } else if value is NSNull {
                out[key] = ""
            }
        }
        return out
    }
}

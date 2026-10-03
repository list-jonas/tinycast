import AppKit
import Foundation

struct ExtensionOAuthAuthorizeOptions: Sendable {
    let url: URL
    let state: String?
}

struct ExtensionOAuthAuthorizeResult: Sendable {
    let authorizationCode: String
    let accessToken: String?
    let state: String?
}

/// An OAuth 2.0 PKCE session: the browser authorizes and an `oauth` callback completes it.
@MainActor
final class ExtensionOAuthSession {
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var expectedState: String?
    private var timeout: Task<Void, Never>?

    private static weak var activeSession: ExtensionOAuthSession?

    /// True while this session is waiting for the browser to come back.
    var isAuthorizing: Bool { continuation != nil }

    enum OAuthError: LocalizedError {
        case canceled
        case failed(String)
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case .canceled: return "Authentication was canceled."
            case .failed(let message): return message
            case .stateMismatch: return "OAuth state mismatch. Please try authenticating again."
            }
        }
    }

    /// What a deep link turned out to be, so the caller can tell "not ours" from "too late".
    enum Callback {
        case delivered
        case expired
        case ignored
    }

    /// Deep links from the app delegate, such as `raycast://oauth?code=…`.
    static func handleCallbackURL(_ url: URL) -> Callback {
        guard let scheme = url.scheme?.lowercased(),
            scheme == "raycast" || scheme == "tinycast" || scheme == "com.raycast"
        else { return .ignored }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        guard
            host == "oauth" || host == "redirect"
                || path == "/oauth" || path == "/redirect"
                || path.hasPrefix("/oauth/") || path.hasPrefix("/redirect/")
        else { return .ignored }

        // The browser can come back after the session is gone: quit, timed out, or torn down.
        guard let active = activeSession else { return .expired }
        active.receiveCallback(url: url)
        return .delivered
    }

    func authorize(options: ExtensionOAuthAuthorizeOptions) async throws -> ExtensionOAuthAuthorizeResult {
        if continuation != nil { cancel() }
        expectedState = options.state
        Self.activeSession = self
        let params = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.finish(error: OAuthError.failed("Authentication timed out."))
            }
            if !NSWorkspace.shared.open(options.url) {
                finish(error: OAuthError.failed("Failed to open authorization URL in default browser."))
            }
        }
        return ExtensionOAuthAuthorizeResult(
            authorizationCode: params["code"] ?? "", accessToken: params["access_token"],
            state: params["state"])
    }

    private func receiveCallback(url: URL) {
        let params = Self.parseCallback(url: url)
        if let error = params["error"] {
            finish(error: OAuthError.failed(params["error_description"] ?? error))
        } else if let expected = expectedState, !expected.isEmpty, params["state"] != expected {
            finish(error: OAuthError.stateMismatch)
        } else {
            finish(result: params)
        }
    }

    private func finish(result: [String: String]? = nil, error: Error? = nil) {
        timeout?.cancel()
        timeout = nil
        if Self.activeSession === self { Self.activeSession = nil }
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let result {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: OAuthError.canceled)
        }
    }

    func cancel() {
        finish(error: OAuthError.canceled)
    }

    static func parseCallback(url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        // Implicit and hash callbacks arrive as `raycast://oauth#code=…`.
        for pair in (components.fragment ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return result
    }
}

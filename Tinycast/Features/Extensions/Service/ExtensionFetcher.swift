import Foundation
import Synchronization

/// Bodies cross the bridge base64-encoded, so binary responses survive.
final class ExtensionFetcher: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieStorage = nil
        // Extensions cache through the Cache API; a shared URL cache would surprise them.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    enum FetchError: LocalizedError {
        case badURL(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let url): return "Invalid URL: \(url)"
            }
        }
    }

    func request(_ spec: RenderValue?) async throws -> [String: Any] {
        let fields = spec?.objectValue ?? [:]
        let urlString = fields["url"]?.stringValue ?? ""
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw FetchError.badURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = fields["method"]?.stringValue ?? "GET"
        for (name, value) in fields["headers"]?.objectValue ?? [:] {
            guard let text = value.stringValue else { continue }
            request.setValue(text, forHTTPHeaderField: name)
        }
        if let base64 = fields["bodyBase64"]?.stringValue, let body = Data(base64Encoded: base64) {
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            guard let name = key as? String, let text = value as? String else { continue }
            headers[name.lowercased()] = text
        }
        let status = http?.statusCode ?? 200
        return [
            "status": status,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: status),
            "headers": headers,
            "url": response.url?.absoluteString ?? urlString,
            "bodyBase64": data.base64EncodedString()
        ]
    }
}

/// `exec`/`execFile` off the JS queue; the sync forms live in `ExtensionNodeShims`.
enum ExtensionAsyncProcess {
    enum ProcessError: LocalizedError {
        case notFound(String)
        case failedToStart(String, String)

        var errorDescription: String? {
            switch self {
            case .notFound(let command):
                return "ENOENT: command not found: '\(command)'"
            case .failedToStart(let command, let reason):
                return "Could not run '\(command)': \(reason)"
            }
        }
    }

    /// An app bundle inherits no login shell, so a bare `brew` would otherwise fail.
    static func resolveExecutable(_ command: String) -> URL? {
        let fileManager = FileManager.default
        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded)
                ? URL(fileURLWithPath: expanded) : nil
        }
        let search =
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [
                "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
                "/sbin"
            ]
        for directory in search {
            let candidate = (directory as NSString).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    static func run(_ spec: RenderValue?) async throws -> [String: Any] {
        let fields = spec?.objectValue ?? [:]
        let command = fields["command"]?.stringValue ?? ""
        let useShell = fields["shell"]?.boolValue ?? false
        let args = (fields["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        let cwd = fields["cwd"]?.stringValue
        let environment = (fields["env"]?.objectValue).map { $0.compactMapValues(\.stringValue) }
        let input = fields["input"]?.stringValue.flatMap { Data(base64Encoded: $0) }
        let timeout = fields["timeout"]?.doubleValue
        let detached = fields["detached"]?.boolValue ?? false

        let execution = Execution()
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let task = Process()
                        if useShell {
                            task.executableURL = URL(fileURLWithPath: "/bin/sh")
                            task.arguments = ["-c", command]
                        } else {
                            guard let resolved = resolveExecutable(command) else { throw ProcessError.notFound(command) }
                            task.executableURL = resolved
                            task.arguments = args
                        }
                        if let cwd, !cwd.isEmpty {
                            task.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
                        }
                        task.environment = environment ?? ProcessInfo.processInfo.environment
                        execution.start(task, input: input, timeout: timeout, detached: detached, continuation: continuation)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            execution.stop(cancelled: true)
        }
        return ["stdout": output.stdout.base64EncodedString(), "stderr": output.stderr.base64EncodedString(),
                "status": Int(output.status), "signal": output.signal as Any? ?? NSNull()]
    }

    private struct Output: Sendable {
        var stdout = Data()
        var stderr = Data()
        var status: Int32 = 0
        var signal: String?
    }

    private final class Execution: Sendable {
        private struct State {
            var process: Process?
            var continuation: CheckedContinuation<Output, Error>?
            var stdout: Pipe?
            var stderr: Pipe?
            var stdin: Pipe?
            var input: Data?
            var inputOffset = 0
            var output = Output()
            var openStreams = 2
            var exited = false
            var cancelled = false
            var stopping = false
            var detached = false
            var watchdog: DispatchSourceTimer?
        }

        private let state = Mutex(State())

        func start(_ process: Process, input: Data?, timeout: Double?, detached: Bool,
                   continuation: CheckedContinuation<Output, Error>) {
            state.withLock { state in
                guard !state.cancelled else { continuation.resume(throwing: CancellationError()); return }
                state.process = process
                state.continuation = continuation
                state.detached = detached
                if detached {
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                } else {
                    let stdout = Pipe(), stderr = Pipe()
                    state.stdout = stdout
                    state.stderr = stderr
                    process.standardOutput = stdout
                    process.standardError = stderr
                    stdout.fileHandleForReading.readabilityHandler = { self.read($0, stderr: false) }
                    stderr.fileHandleForReading.readabilityHandler = { self.read($0, stderr: true) }
                    process.terminationHandler = { self.terminated($0) }
                }
                if let input, !input.isEmpty {
                    let stdin = Pipe()
                    state.stdin = stdin
                    state.input = input
                    process.standardInput = stdin
                    let descriptor = stdin.fileHandleForWriting.fileDescriptor
                    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                } else { process.standardInput = FileHandle.nullDevice }
                do { try process.run() } catch {
                    finish(&state, result: .failure(ProcessError.failedToStart(
                        process.executableURL?.path ?? "", error.localizedDescription)))
                    return
                }
                state.stdin?.fileHandleForWriting.writeabilityHandler = { self.write($0) }
                if detached {
                    state.continuation = nil
                    state.process = nil
                    continuation.resume(returning: Output())
                } else if let timeout, timeout > 0 {
                    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    timer.schedule(deadline: .now() + timeout / 1000)
                    timer.setEventHandler { [weak self] in self?.stop(cancelled: false) }
                    state.watchdog = timer
                    timer.resume()
                }
            }
        }

        private func read(_ handle: FileHandle, stderr: Bool) {
            state.withLock { state in
                guard state.continuation != nil, !state.stopping,
                    (stderr ? state.stderr : state.stdout) != nil else { return }
                let data = handle.availableData
                if !data.isEmpty {
                    if stderr { state.output.stderr.append(data) } else { state.output.stdout.append(data) }
                } else {
                    handle.readabilityHandler = nil
                    try? handle.close()
                    if stderr { state.stderr = nil } else { state.stdout = nil }
                    state.openStreams -= 1
                    completeIfReady(&state)
                }
            }
        }

        private func write(_ handle: FileHandle) {
            state.withLock { state in
                guard let input = state.input else { return }
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: state.inputOffset),
                                 min(65_536, input.count - state.inputOffset))
                }
                if count > 0 { state.inputOffset += count }
                if state.inputOffset == input.count || (count < 0 && errno != EAGAIN && errno != EINTR) {
                    closeInput(&state)
                }
            }
        }

        private func terminated(_ process: Process) {
            state.withLock { state in
                guard state.continuation != nil else { return }
                state.exited = true
                state.output.status = process.terminationStatus
                if process.terminationReason == .uncaughtSignal {
                    state.output.signal = process.terminationStatus == SIGKILL ? "SIGKILL" : "SIGTERM"
                }
                closeInput(&state)
                completeIfReady(&state)
            }
        }

        func stop(cancelled: Bool) {
            let needsTermination = state.withLock { state in
                guard !state.detached else { return false }
                state.cancelled = state.cancelled || cancelled
                guard !state.stopping else { return false }
                state.stopping = true
                closeStreams(&state)
                state.openStreams = 0
                if state.process?.isRunning == true { state.process?.terminate() }
                completeIfReady(&state)
                return state.process != nil
            }
            guard needsTermination else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                self.state.withLock { state in
                    if let process = state.process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }

        private func completeIfReady(_ state: inout State) {
            guard state.exited, state.openStreams == 0 else { return }
            finish(&state, result: state.cancelled ? .failure(CancellationError()) : .success(state.output))
        }

        private func closeInput(_ state: inout State) {
            state.stdin?.fileHandleForWriting.writeabilityHandler = nil
            try? state.stdin?.fileHandleForWriting.close()
            state.stdin = nil
            state.input = nil
        }

        private func closeStreams(_ state: inout State) {
            for pipe in [state.stdout, state.stderr].compactMap({ $0 }) {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
            }
            state.stdout = nil
            state.stderr = nil
            closeInput(&state)
        }

        private func finish(_ state: inout State, result: Result<Output, Error>) {
            let continuation = state.continuation
            state.continuation = nil
            state.process?.terminationHandler = nil
            state.process = nil
            state.watchdog?.cancel()
            state.watchdog = nil
            closeStreams(&state)
            state.output = Output()
            continuation?.resume(with: result)
        }
    }

    /// A child filling the 64 KB pipe blocks before it can exit, so the drain comes first.
    static func drain(
        _ task: Process, stdout: Pipe, stderr: Pipe, timeout: Double?
    ) -> (Data, Data) {
        var watchdog: DispatchSourceTimer?
        if let timeout, timeout > 0 { watchdog = terminationWatchdog(task, after: timeout / 1000) }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog?.cancel()
        return (outData, errData)
    }

    private static func terminationWatchdog(
        _ task: Process, after seconds: Double
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { if task.isRunning { task.terminate() } }
        timer.resume()
        return timer
    }
}

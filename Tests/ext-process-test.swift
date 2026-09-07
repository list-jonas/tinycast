import Foundation

extension ExtensionTests {
    private static func spec(_ code: String, path: URL, fields: [String: RenderValue] = [:]) -> RenderValue {
        .object(fields.merging([
            "command": .string("/usr/bin/python3"),
            "args": .array([.string("-c"), .string(code), .string(path.path)])
        ]) { _, value in value })
    }

    private static func waitForPID(_ path: URL) async -> Int32? {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: path, encoding: .utf8), let pid = Int32(text) { return pid }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @MainActor
    static func processChecks() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tinycast-process-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for stubborn in [false, true] {
            let path = directory.appendingPathComponent("cancel-\(stubborn)")
            let code = """
                import os, signal, sys, time
                if \(stubborn ? "True" : "False"): signal.signal(signal.SIGTERM, signal.SIG_IGN)
                os.write(1, b'o')
                os.write(2, b'e')
                with open(sys.argv[1], 'w') as file: file.write(str(os.getpid()))
                time.sleep(30)
                """
            let task = Task {
                do {
                    _ = try await ExtensionAsyncProcess.run(spec(code, path: path))
                    return false
                } catch is CancellationError { return true } catch { return false }
            }
            let pid = await waitForPID(path)
            let start = ContinuousClock.now
            task.cancel()
            let cancelled = await task.value
            check("cancellation completes promptly (ignores TERM: \(stubborn))",
                  cancelled && start.duration(to: .now) < .seconds(2))
            let reaped = pid.map { kill($0, 0) == -1 && errno == ESRCH } ?? false
            check("cancelled child is reaped (ignores TERM: \(stubborn))", reaped)
            if let pid, !reaped { kill(pid, SIGKILL) }
        }

        let input = Data(repeating: 65, count: 262_144)
        let echo = spec("""
            import sys
            sys.stderr.buffer.write(b'e' * 262144)
            sys.stderr.buffer.flush()
            sys.stdout.buffer.write(sys.stdin.buffer.read())
            """, path: directory, fields: ["input": .string(input.base64EncodedString()), "timeout": .number(3000)])
        let echoed = try? await ExtensionAsyncProcess.run(echo)
        check("large stdin and both output pipes drain concurrently",
              (echoed?["stdout"] as? String).flatMap { Data(base64Encoded: $0) } == input
              && (echoed?["stderr"] as? String).flatMap { Data(base64Encoded: $0) }?.count == 262_144
              && echoed?["status"] as? Int == 0)

        let timeoutPath = directory.appendingPathComponent("timeout")
        let start = ContinuousClock.now
        let timed = try? await ExtensionAsyncProcess.run(spec("""
            import os, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(sys.argv[1], 'w') as file: file.write(str(os.getpid()))
            time.sleep(30)
            """, path: timeoutPath, fields: ["timeout": .number(500)]))
        check("timeout escalates and reports the terminating signal", timed?["signal"] as? String == "SIGKILL"
              && timed?["status"] as? Int == Int(SIGKILL) && start.duration(to: .now) < .seconds(2))
        if let text = try? String(contentsOf: timeoutPath, encoding: .utf8), let pid = Int32(text) {
            let reaped = kill(pid, 0) == -1 && errno == ESRCH
            check("timed out child is reaped", reaped)
            if !reaped { kill(pid, SIGKILL) }
        } else { check("timeout fixture started", false) }

        let earlyPath = directory.appendingPathComponent("early")
        let early = Task {
            do {
                _ = try await ExtensionAsyncProcess.run(spec("open(__import__('sys').argv[1], 'w').close()", path: earlyPath))
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        early.cancel()
        let cancelledBeforeStart = await early.value
        check("cancellation before start never spawns the child",
              cancelledBeforeStart && !FileManager.default.fileExists(atPath: earlyPath.path))

        let detachedPath = directory.appendingPathComponent("detached")
        let detached = Task {
            try? await ExtensionAsyncProcess.run(spec("""
                import os, sys, time
                with open(sys.argv[1], 'w') as file: file.write(str(os.getpid()))
                time.sleep(0.4)
                sys.stdout.buffer.write(b'o' * 262144)
                sys.stderr.buffer.write(b'e' * 262144)
                open(sys.argv[1] + '.done', 'w').close()
                """, path: detachedPath, fields: ["detached": .bool(true)]))["status"] as? Int
        }
        let detachedPID = await waitForPID(detachedPath)
        detached.cancel()
        let detachedStatus = await detached.value
        check("detached child survives caller cancellation", detachedStatus == 0
              && detachedPID.map { kill($0, 0) == 0 } == true)
        try? await Task.sleep(for: .milliseconds(600))
        check("detached output does not fill abandoned pipes",
              FileManager.default.fileExists(atPath: detachedPath.path + ".done"))
        if let detachedPID, kill(detachedPID, 0) == 0 { kill(detachedPID, SIGKILL) }

        do {
            let missing = directory.appendingPathComponent("missing").path
            _ = try await ExtensionAsyncProcess.run(.object(["command": .string(missing)]))
            check("spawn failures return an error", false)
        } catch { check("spawn failures return an error", true) }
    }
}

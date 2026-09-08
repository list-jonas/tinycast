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
        await spawnLifecycleChecks()
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

    @MainActor
    private static func spawnLifecycleChecks() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tinycast-spawn-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (runtime, host, recorder) = makeRuntime()
        defer { runtime.shutdown() }
        try? await runtime.boot(config: .current(supportDirectory: directory))
        let code = """
            const { spawn } = require("child_process");
            const { showHUD } = require("@raycast/api");
            module.exports.default = async () => {
              const cases = [
                ["default", { detached: true }],
                ["pipes", { detached: true, stdio: ["ignore", "pipe", "pipe"] }],
                ["piped-unref", { detached: true }, "unref"],
                ["ignored", { detached: true, stdio: "ignore" }],
                ["ref-restored", { detached: true, stdio: "ignore" }, "ref"],
              ];
              for (const [name, options, reference] of cases) {
                await new Promise((resolve, reject) => {
                  const child = spawn("/bin/sh", ["-c", "sleep 0.05; printf ports; printf warning >&2; exit 7"], options);
                  if (reference) child.unref();
                  if (reference === "ref") child.ref();
                  let stdout = "", stderr = "";
                  child.stdout.on("data", data => { stdout += data; });
                  child.stderr.on("data", data => { stderr += data; });
                  child.on("error", reject);
                  child.on("close", status => {
                    showHUD(name + ":" + status + ":" + stdout + ":" + stderr).then(resolve, reject);
                  });
                });
              }
              const directory = \(ExtensionRuntime.jsonString(from: directory.path));
              const waitForRelease = 'i=0; while [ ! -f "$1/release" ] && [ "$i" -lt 100 ]; do ' +
                'sleep 0.05; i=$((i+1)); done; [ -f "$1/release" ] && printf done > "$2"';
              for (const [index, stdio] of ["ignore", ["ignore", "ignore", "ignore"]].entries()) {
                spawn("/bin/sh", ["-c", waitForRelease, "fixture", directory, directory + "/" + index],
                  { detached: true, stdio }).unref();
              }
            };
            """
        await runtime.start(session: "spawn", code: code, file: directory.appendingPathComponent("fixture.js"),
                            mode: .noView, context: launchContext(mode: .noView))
        for _ in 0..<150 where !recorder.finished { await settle(20) }
        check("spawn lifecycle command finishes", recorder.finished && recorder.failures.isEmpty,
              recorder.failures.joined())
        for name in ["default", "pipes", "piped-unref"] {
            check("detached \(name) retains output and exit status", host.huds.contains("\(name):7:ports:warning"))
        }
        for name in ["ignored", "ref-restored"] {
            check("referenced \(name) waits for exit", host.huds.contains { $0.hasPrefix("\(name):7:") })
        }
        await runtime.drainHostCalls()
        check("unreferenced ignored children do not hold the command open",
              (0...1).allSatisfy { !FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0)").path) })
        runtime.shutdown()
        try? Data().write(to: directory.appendingPathComponent("release"))
        await settle(650)
        check("unreferenced ignored children survive runtime teardown",
              (0...1).allSatisfy {
                  (try? String(contentsOf: directory.appendingPathComponent("\($0)"), encoding: .utf8)) == "done"
              })
    }
}

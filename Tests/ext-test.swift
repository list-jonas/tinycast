// Compiles the real engine sources against JavaScriptCore; pass a directory to run one.

import AppKit
import Foundation
import SwiftUI

@main
struct ExtensionTests {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let directory = arguments.first {
            await runInstalledExtension(
                directory: URL(fileURLWithPath: directory), command: arguments.dropFirst().first)
        } else {
            await runChecks()
        }
    }

    // MARK: - Harness plumbing

    /// `proc` and `fetch` are the app's real ones; main-actor calls get canned answers.
    @MainActor
    final class StubHost: ExtensionHostAPI {
        var calls: [String] = []
        var toasts: [String] = []
        var huds: [String] = []
        var oauthTokens: [String: String] = [:]
        private let fetcher = ExtensionFetcher()
        private let sockets = ExtensionWebSocketBridge()

        func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
            calls.append("\(api).\(method)")
            if api == "proc", method == "wait" {
                return ExtensionRuntime.jsonString(
                    from: try await ExtensionAsyncProcess.wait(arguments.first))
            }
            if api == "proc", method == "read" {
                return ExtensionRuntime.jsonString(from: try await ExtensionAsyncProcess.read(arguments))
            }
            if api == "fetch" {
                return ExtensionRuntime.jsonString(from: try await fetcher.request(arguments.first))
            }
            if api == "websocket" {
                return ExtensionRuntime.jsonString(
                    from: try await sockets.perform(method: method, arguments: arguments))
            }
            if api == "dns" {
                return ExtensionRuntime.jsonString(from: await ExtensionNameResolver.resolve(arguments.first))
            }
            switch "\(api).\(method)" {
            case "feedback.showToast":
                toasts.append(arguments.first?.objectValue?["title"]?.stringValue ?? "")
                return "1"
            case "feedback.showHUD":
                huds.append(arguments.first?.stringValue ?? "")
                return ""
            case "storage.get", "clipboard.readText":
                return #""""#
            case "storage.all":
                return "{}"
            case "system.frontmostApplication":
                return
                    #"{"name":"Finder","path":"/System/Library/CoreServices/Finder.app","bundleId":"com.apple.finder"}"#
            case "system.applications":
                return "[]"
            case "oauth.authorize":
                let state = arguments[safe: 1]?.stringValue ?? ""
                return "{\"authorizationCode\":\"auth_code_swift_test\",\"state\":\"\(state)\"}"
            case "oauth.getTokens":
                let providerId = arguments.first?.stringValue ?? ""
                return oauthTokens[providerId] ?? ""
            case "oauth.setTokens":
                let providerId = arguments.first?.stringValue ?? ""
                let tokens = arguments[safe: 1]?.stringValue ?? ""
                oauthTokens[providerId] = tokens
                return ""
            case "oauth.removeTokens":
                let providerId = arguments.first?.stringValue ?? ""
                oauthTokens.removeValue(forKey: providerId)
                return ""
            default:
                return ""
            }
        }

        func sessionEnded() {
            sockets.closeAll()
        }
    }

    @MainActor
    final class Recorder: ExtensionRuntimeDelegate {
        var trees: [RenderTree] = []
        var failures: [String] = []
        var logs: [String] = []
        var finished = false

        func runtime(_ runtime: ExtensionRuntime, session: String, didRender tree: RenderTree) {
            trees.append(tree)
        }
        func runtime(_ runtime: ExtensionRuntime, session: String, didFail message: String) {
            failures.append(message)
        }
        func runtime(_ runtime: ExtensionRuntime, session: String, navigationDepth: Int) {}
        func runtime(_ runtime: ExtensionRuntime, session: String, didFinish: Void) { finished = true }
        func runtime(_ runtime: ExtensionRuntime, log level: String, message: String) {
            logs.append("[\(level)] \(message)")
        }
    }

    /// The generated runtime, found relative to this source file's repository.
    static func runtimeURL() -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tinycast/Resources/RaycastRuntime.generated.js"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tinycast/Resources/RaycastRuntime.generated.js")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    @MainActor
    static func makeRuntime() -> (ExtensionRuntime, StubHost, Recorder) {
        let host = StubHost()
        let recorder = Recorder()
        let runtime = ExtensionRuntime(hostAPI: host, runtimeURL: runtimeURL())
        runtime.setDelegate(recorder)
        return (runtime, host, recorder)
    }

    static func launchContext(
        extensionName: String = "fixture", command: String = "fixture",
        mode: ExtensionCommandMode = .view, assets: String = "/tmp",
        preferences: [String: ExtensionPreferenceValue] = [:],
        arguments: [String: String] = [:], isDarkAppearance: Bool = true
    ) -> ExtensionLaunchContext {
        ExtensionLaunchContext(
            extensionName: extensionName, extensionTitle: extensionName, commandName: command,
            commandMode: mode, assetsPath: assets, supportPath: "/tmp",
            preferences: preferences, caches: [:], arguments: arguments, fallbackText: nil,
            isDarkAppearance: isDarkAppearance)
    }

    /// `EXT_TEST_ARGS="hours=0,minutes=5"` — stands in for the palette's inline argument fields.
    static func environmentArguments() -> [String: String] {
        guard let raw = ProcessInfo.processInfo.environment["EXT_TEST_ARGS"] else { return [:] }
        var arguments: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            arguments[String(parts[0])] = String(parts[1])
        }
        return arguments
    }

    /// `EXT_TEST_PREFS` as JSON — strings and bools, what a manifest preference holds.
    static func environmentPreferences() -> [String: ExtensionPreferenceValue] {
        guard let raw = ProcessInfo.processInfo.environment["EXT_TEST_PREFS"],
            let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { return [:] }
        return json.compactMapValues { value in
            if let flag = value as? Bool { return .bool(flag) }
            if let text = value as? String { return .string(text) }
            return nil
        }
    }

    /// Let the JS event loop and the main-actor host hops settle.
    static func settle(_ milliseconds: UInt64 = 250) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    // MARK: - Results

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL  \(label)\(detail.isEmpty ? "" : "\n      \(detail)")")
        }
    }

    // MARK: - Checks

    @MainActor
    static func runChecks() async {
        manifestChecks()
        renderNodeChecks()
        screenChecks()
        actionIconChecks()
        oauthUnitChecks()
        deepLinkChecks()
        nodeShimChecks()
        await runtimeChecks()
        await searchAccessoryRuntimeChecks()
        await nodeContractChecks()
        await webAssemblyChecks()
        await asyncComponentChecks()
        await menuBarRuntimeChecks()
        await menuBarHostChecks()
        await ExtensionFetchTests.runChecks()

        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func nodeShimChecks() {
        let result = ExtensionNodeShims().perform(api: "os", method: "cpus", argsJSON: "[]")
        guard
            let data = result.data(using: .utf8),
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            envelope["ok"] as? Bool == true,
            let processors = envelope["value"] as? [[String: Any]]
        else {
            check("os.cpus host call succeeds", false, result)
            return
        }

        check(
            "os.cpus returns every processor",
            processors.count == ProcessInfo.processInfo.processorCount,
            "\(processors.count)")
        let expectedStates = Set(["user", "nice", "sys", "idle", "irq"])
        let valid = processors.allSatisfy { processor in
            guard
                processor["model"] is String,
                processor["speed"] is NSNumber,
                let times = processor["times"] as? [String: NSNumber],
                Set(times.keys) == expectedStates
            else { return false }
            return times.values.allSatisfy { $0.doubleValue.isFinite && $0.doubleValue >= 0 }
        }
        check("os.cpus returns finite Node timing fields", valid, result)

        func value(_ method: String) -> Any? {
            let result = ExtensionNodeShims().perform(api: "os", method: method, argsJSON: "[]")
            guard let data = result.data(using: .utf8),
                let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                envelope["ok"] as? Bool == true
            else { return nil }
            return envelope["value"]
        }
        let uptime = (value("uptime") as? NSNumber)?.doubleValue
        check("os.uptime returns the system uptime", uptime.map { $0 > 0 } == true)
        let freeMemory = (value("freemem") as? NSNumber)?.doubleValue
        check(
            "os.freemem returns finite bytes",
            freeMemory.map { $0.isFinite && $0 >= 0 && $0 <= Double(ProcessInfo.processInfo.physicalMemory) }
                == true)
        let loadAverages = value("loadavg") as? [NSNumber]
        check(
            "os.loadavg returns three finite values",
            loadAverages?.count == 3
                && loadAverages?.allSatisfy { $0.doubleValue.isFinite && $0.doubleValue >= 0 } == true)
    }

    @MainActor
    static func menuBarRuntimeChecks() async {
        for (value, expected) in [("10m", 600.0), ("1h", 3600), ("1d", 86400), ("30s", 30), ("1s", 10)] {
            check("interval \(value)", ExtensionRefreshPolicy.parse(value, floor: 10) == expected)
        }
        for value in ["", "0m", "-1m", "NaNm", "Infinityh", "1e308d", "5x"] {
            check("reject interval \(value)", ExtensionRefreshPolicy.parse(value, floor: 10) == nil)
        }
        let (runtime, _, recorder) = makeRuntime()
        defer { runtime.shutdown() }
        try? await runtime.boot(config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        var context = launchContext(mode: .menuBar)
        context.launchType = .background
        context.launchContext = ["source": .string("fixture")]
        let code = #"""
            const React = require("react");
            const { MenuBarExtra, environment } = require("@raycast/api");
            module.exports.default = function(props) {
              const [title, setTitle] = React.useState(props.launchType + "|" + environment.launchType);
              return React.createElement(MenuBarExtra, { title, tooltip: props.launchContext.source },
                React.createElement(MenuBarExtra.Item, { title: "Refresh", onAction: async (event) => {
                  await new Promise(resolve => setTimeout(resolve, 40));
                  setTitle(event.type);
                }, alternate: React.createElement(MenuBarExtra.Item, { title: "Alternate", onAction() {} }) }));
            };
            """#
        await runtime.start(
            session: "bar", code: code, file: URL(fileURLWithPath: "/tmp/menu.js"),
            mode: .menuBar, context: context)
        await settle()
        let root = recorder.trees.last?.activeRoot
        check("menu-bar renders in JavaScriptCore", root?.type == "MenuBarExtra", recorder.failures.joined())
        check(
            "background launch reaches props and environment",
            root?.string("title") == "background|background")
        check("launch context reaches props", root?.string("tooltip") == "fixture")
        check(
            "alternate survives serialization",
            root?.children.first?.node("alternate")?.handler("onAction") != nil)
        if let handler = root?.children.first?.handler("onAction") {
            await runtime.dispatch(
                session: "bar", handler: handler, payload: #"[{"type":"right-click"}]"#,
                completesSession: true)
            check("menu action does not finish before its promise", !recorder.finished)
            await settle()
            check("menu action finishes after its promise", recorder.finished)
            check(
                "menu action forwards event",
                recorder.trees.last?.activeRoot?.string("title") == "right-click")
        }
        await runtime.stop(session: "bar")
    }

    // MARK: - Running a real extension

    @MainActor
    static func runInstalledExtension(directory: URL, command commandName: String?) async {
        guard let manifest = try? ExtensionManifest.load(directory: directory) else {
            print("Not an extension: \(directory.path)")
            exit(1)
        }
        let runnable = manifest.commands
        guard
            let target = commandName.flatMap({ name in runnable.first { $0.name == name } })
                ?? runnable.first
        else {
            print("No runnable command in \(manifest.title)")
            exit(1)
        }
        if target.mode == .menuBar, ProcessInfo.processInfo.environment["EXT_TEST_MENU_BAR"] != nil {
            await runInstalledMenuBar(
                InstalledExtension(manifest: manifest, directory: directory), command: target)
            exit(failures == 0 ? 0 : 1)
        }
        let bundle = directory.appendingPathComponent("\(target.name).js")
        guard let code = try? String(contentsOf: bundle, encoding: .utf8) else {
            print("Missing built bundle: \(bundle.path)")
            exit(1)
        }

        print("▶ \(manifest.title) — \(target.title) (\(target.mode.rawValue))")
        let (runtime, host, recorder) = makeRuntime()
        do {
            try await runtime.boot(config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        } catch {
            print("boot failed: \(error.localizedDescription)")
            exit(1)
        }

        var preferences: [String: ExtensionPreferenceValue] = [:]
        for schema in manifest.preferences + target.preferences {
            preferences[schema.name] = schema.effectiveDefault
        }
        // `EXT_TEST_PREFS` stands in for Settings: many extensions have no manifest default.
        for (key, value) in environmentPreferences() { preferences[key] = value }
        let context = launchContext(
            extensionName: manifest.name, command: target.name, mode: target.mode,
            assets: directory.appendingPathComponent("assets").path, preferences: preferences,
            arguments: target.completeArguments(environmentArguments()))
        let settleMS = UInt64(
            ProcessInfo.processInfo.environment["EXT_TEST_SETTLE_MS"].flatMap(UInt64.init) ?? 1500)

        // `EXT_TEST_RERUN=1` runs, tears down and runs again: the works-once-then-hangs case.
        if ProcessInfo.processInfo.environment["EXT_TEST_RERUN"] != nil {
            await runtime.start(
                session: "r1", code: code, file: bundle, mode: target.mode, context: context)
            await settle(settleMS)
            print("run 1: \(recorder.trees.count) render(s), \(recorder.failures.count) failure(s)")
            await runtime.stop(session: "r1")
            runtime.shutdown()
            let first = recorder.trees.count
            try? await runtime.boot(
                config: .current(supportDirectory: FileManager.default.temporaryDirectory))
            print("→ tore down after \(first) render(s); re-running in a fresh context")
        }

        await runtime.start(
            session: "s1", code: code, file: bundle, mode: target.mode, context: context)
        await settle(settleMS)

        for failure in recorder.failures { print("✗ \(failure)") }
        if ProcessInfo.processInfo.environment["EXT_TEST_VERBOSE"] != nil {
            for line in recorder.logs { print("  \(line)") }
        }
        print(
            "\(recorder.trees.count) render(s); host calls: \(Set(host.calls).sorted().joined(separator: ", "))"
        )
        for toast in host.toasts { print("  toast: \(toast)") }
        for hud in host.huds { print("  hud: \(hud)") }
        if let tree = recorder.trees.last {
            let screen = ExtensionScreen(tree: tree, query: "")
            print("root: \(screen.kind)  rows: \(screen.rows.count)  fields: \(screen.fields.count)")
            for item in screen.items.prefix(12) {
                let node = item.node
                let accessories = node.array("accessories").count
                print(
                    "  • \(node.string("title") ?? "")"
                        + (node.string("subtitle").map { "  —  \($0)" } ?? "")
                        + (accessories > 0 ? "  [\(accessories) accessories]" : "")
                        + (node.node("actions") != nil ? "  ⌘K" : ""))
            }
            if case .detail = screen.kind {
                print("  markdown: \((screen.root?.string("markdown") ?? "").prefix(200))")
            }
        }
        await runtime.stop(session: "s1")
        exit(recorder.failures.isEmpty ? 0 : 1)
    }
}

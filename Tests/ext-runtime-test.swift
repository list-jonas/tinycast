import Foundation

extension ExtensionTests {
    @MainActor
    static func runtimeChecks() async {
        let runtimeFile = runtimeURL()
        guard FileManager.default.fileExists(atPath: runtimeFile.path) else {
            check("RaycastRuntime.generated.js exists", false, runtimeFile.path)
            return
        }
        check("RaycastRuntime.generated.js exists", true)

        let (runtime, host, recorder) = makeRuntime()
        do {
            try await runtime.boot(
                config: .current(supportDirectory: FileManager.default.temporaryDirectory))
            check("runtime boots in JavaScriptCore", true)
        } catch {
            check("runtime boots in JavaScriptCore", false, error.localizedDescription)
            return
        }

        // A synthetic command exercising React state, the node shims, timers and host calls.
        let command = """
            "use strict";
            const { List, ActionPanel, Action, Icon, showToast, Toast } = require("@raycast/api");
            const React = require("react");
            const path = require("node:path");
            const os = require("node:os");
            const crypto = require("node:crypto");
            const { fileURLToPath, pathToFileURL } = require("node:url");
            const util = require("node:util");
            const h = React.createElement;
            module.exports.default = function Command() {
              const [count, setCount] = React.useState(0);
              const [derived, setDerived] = React.useState("pending");
              React.useEffect(() => {
                const timer = setTimeout(() => setCount(1), 20);
                crypto.pbkdf2("foobar", "foobarbazzybaz", 1e5, 64, "sha512", (error, key) =>
                  setDerived(error ? error.message : key.toString("hex").slice(0, 16)));
                showToast({ style: Toast.Style.Success, title: "hello" });
                return () => clearTimeout(timer);
              }, []);
              const digest = crypto.createHash("sha256").update("abc").digest("hex").slice(0, 8);
              const cpu = os.cpus()[0];
              const cpuTimes = Object.values(cpu.times).every(Number.isFinite) ? "cpu=ok" : "cpu=bad";
              // AbortSignal's statics, the brand node-fetch checks, and url.parse's legacy `path`.
              const abortable = [
                typeof AbortSignal.timeout, typeof AbortSignal.abort, typeof AbortSignal.any,
                String(AbortSignal.timeout(5e3).aborted), AbortSignal.abort().reason.name,
                Object.getPrototypeOf(AbortSignal.abort()).constructor.name,
                Object.prototype.toString.call(AbortSignal.abort()),
                require("node:url").parse("https://a.test/ajax.php?f=list").path,
              ].join(",");
              const errorCode = (callback) => {
                try { callback(); return "none"; } catch (error) { return error.code; }
              };
              const filePaths = [
                fileURLToPath("file:///Applications/Tinycast%20Beta.app"),
                fileURLToPath(pathToFileURL("/tmp/a#b.png")),
                pathToFileURL("/tmp/My Image.png").href,
                errorCode(() => fileURLToPath("file:///tmp/a%2Fb")),
                errorCode(() => fileURLToPath("file://example.com/tmp/a")),
                errorCode(() => fileURLToPath("https://example.com/a")),
              ].join("\\n");
              // execa and undici read all of these at module scope; each was once a TypeError.
              const debug = util.debuglog("execa");
              const utilShim = [
                typeof debug, String(debug.enabled), String(debug("ignored")),
                util.stripVTControlCharacters("\\u001B[31mred\\u001B[39m"),
                util.formatWithOptions({ colors: true }, "%s=%d", "n", 2),
                String(util.inspect.custom === Symbol.for("nodejs.util.inspect.custom")),
                typeof util.aborted(AbortSignal.abort()).then,
              ].join(",");
              // Bitwarden derives its session hash and caches the vault through exactly these calls.
              const encrypter = crypto.createCipheriv("aes-256-cbc", "k".repeat(32), "i".repeat(16));
              const encrypted = Buffer.concat([encrypter.update("hello tinycast"), encrypter.final()]);
              const decrypter = crypto.createDecipheriv("aes-256-cbc", "k".repeat(32), Buffer.from("i".repeat(16)));
              const ecb = crypto.createCipheriv("aes-128-ecb", Buffer.alloc(16, 1), null).setAutoPadding(false);
              const cipherShim = [
                crypto.pbkdf2Sync("password", "salt", 1000, 16, "sha512").toString("hex"),
                crypto.pbkdf2Sync("", "", 1, 8, "SHA-256").toString("hex"),
                crypto.createCipheriv("aes-256-cbc", "k".repeat(32), "i".repeat(16)).final("hex"),
                encrypted.toString("hex"),
                decrypter.update(encrypted.toString("hex"), "hex", "utf8") + decrypter.final("utf8"),
                ecb.update(Buffer.alloc(16, 2)).toString("hex") + ecb.final("hex"),
                errorCode(() => {
                  const wrong = crypto.createDecipheriv("aes-256-cbc", "k".repeat(32), "i".repeat(16));
                  wrong.update(Buffer.alloc(16));
                  wrong.final();
                }),
                errorCode(() => crypto.createCipheriv("aes-256-cbc", "short", "i".repeat(16))),
                errorCode(() => crypto.pbkdf2Sync("p", "s", 1, 8, "nope")),
                derived,
              ].join(",");
              return h(List, { navigationTitle: "Synthetic", isLoading: false },
                h(List.Item, {
                  title: "count=" + count,
                  subtitle: path.join("/a/b", "../c"),
                  icon: Icon.Circle,
                  accessories: [
                    { text: digest }, { text: abortable }, { text: filePaths },
                    { text: cpuTimes }, { text: cipherShim }, { text: utilShim },
                  ],
                  actions: h(ActionPanel, null,
                    h(Action, { title: "Bump", onAction: () => setCount((v) => v + 10) }))
                }));
            };
            """
        await runtime.start(
            session: "s1", code: command, file: URL(fileURLWithPath: "/tmp/synthetic.js"),
            mode: .view, context: launchContext())
        await settle()

        check("no failures", recorder.failures.isEmpty, recorder.failures.joined(separator: "\n"))
        check("rendered at least once", !recorder.trees.isEmpty)

        guard var screen = recorder.trees.last.map({ ExtensionScreen(tree: $0, query: "") }) else {
            check("screen builds from the live tree", false)
            return
        }
        check("screen builds from the live tree", true)
        check("navigation title", screen.navigationTitle == "Synthetic")
        check(
            "timer fired and re-rendered",
            screen.items.first?.node.string("title") == "count=1",
            screen.items.first?.node.string("title") ?? "nil")
        check(
            "node path shim", screen.items.first?.node.string("subtitle") == "/a/c",
            screen.items.first?.node.string("subtitle") ?? "nil")
        check(
            "crypto shim",
            ExtensionAccessoriesView_labelForTest(screen.items.first?.node.array("accessories").first)
                == "ba7816bf",
            String(describing: screen.items.first?.node.array("accessories").first))
        check(
            "os.cpus crosses the synchronous host bridge",
            ExtensionAccessoriesView_labelForTest(
                screen.items.first?.node.array("accessories").dropFirst(3).first) == "cpu=ok",
            String(describing: screen.items.first?.node.array("accessories")))
        check("toast reached the host", host.toasts == ["hello"], host.toasts.joined(separator: ","))
        check(
            "AbortSignal survives node-fetch's brand checks, and url.parse keeps its path",
            ExtensionAccessoriesView_labelForTest(
                screen.items.first?.node.array("accessories").dropFirst().first)
                == "function,function,function,false,AbortError,AbortSignal,"
                + "[object AbortSignal],/ajax.php?f=list",
            String(describing: screen.items.first?.node.array("accessories").dropFirst().first))
        check(
            "fileURLToPath decodes a path and rejects an unusable URL",
            ExtensionAccessoriesView_labelForTest(
                screen.items.first?.node.array("accessories").dropFirst(2).first)
                == "/Applications/Tinycast Beta.app\n/tmp/a#b.png\n"
                + "file:///tmp/My%20Image.png\n"
                + "ERR_INVALID_FILE_URL_PATH\nERR_INVALID_FILE_URL_HOST\n"
                + "ERR_INVALID_URL_SCHEME",
            String(describing: screen.items.first?.node.array("accessories").dropFirst(2).first))
        check(
            "crypto shim derives PBKDF2 keys and round-trips AES like Node",
            ExtensionAccessoriesView_labelForTest(
                screen.items.first?.node.array("accessories").dropFirst(4).first)
                == "afe6c5530785b6cc6b1c6453384731bd,f7ce0b653d2d72a4,5d11c49af18b4b3e482508362bd2c857,"
                + "eb7b227687302ff167fef6a04d9f99f3,"
                + "hello tinycast,17d614f379a9359077e95577fd31c20a,ERR_OSSL_BAD_DECRYPT,"
                + "ERR_CRYPTO_INVALID_KEYLEN,ERR_CRYPTO_INVALID_DIGEST,6cba6dd1d44f53a3",
            String(describing: screen.items.first?.node.array("accessories").dropFirst(4).first))
        check(
            "util shim answers debuglog, stripVTControlCharacters, aborted and inspect.custom",
            ExtensionAccessoriesView_labelForTest(screen.items.first?.node.array("accessories").last)
                == "function,false,undefined,red,n=2,true,function",
            String(describing: screen.items.first?.node.array("accessories").last))

        // Dispatch the row's action and confirm the re-render.
        let actions = ExtensionScreen.actions(in: screen.actionPanel(forItemAt: 0))
        check("action is dispatchable", actions.first?.handler != nil)
        if let handler = actions.first?.handler {
            await runtime.dispatch(
                session: "s1", handler: handler,
                payload: ExtensionRuntime.jsonString(from: []))
            await settle()
            screen = ExtensionScreen(tree: recorder.trees.last!, query: "")
            check(
                "action re-rendered the row",
                screen.items.first?.node.string("title") == "count=11",
                screen.items.first?.node.string("title") ?? "nil")
        }

        // OAuth PKCE and TokenSet runtime tests
        let (oauthRuntime, oauthHost, oauthRecorder) = makeRuntime()
        try? await oauthRuntime.boot(
            config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        let oauthCommand = """
            "use strict";
            const { OAuth, showHUD } = require("@raycast/api");
            module.exports.default = async function () {
              const client = new OAuth.PKCEClient({
                redirectMethod: OAuth.RedirectMethod.Web,
                providerName: "GitHub",
                providerId: "gh",
              });
              const req = await client.authorizationRequest({
                endpoint: "https://github.com/login/oauth/authorize",
                clientId: "id123",
              });
              const auth = await client.authorize(req);
              const tokens = new OAuth.TokenSet({
                accessToken: "token_" + auth.authorizationCode,
                refreshToken: "refresh_123",
                expiresIn: 3600,
              });
              await client.setTokens(tokens);
              const read = await client.getTokens();
              await showHUD(read.accessToken);
            };
            """
        await oauthRuntime.start(
            session: "sOAuth", code: oauthCommand,
            file: URL(fileURLWithPath: "/tmp/oauth.js"), mode: .noView,
            context: launchContext(mode: .noView))
        await settle()
        check("oauth command finished", oauthRecorder.finished, oauthRecorder.failures.joined())
        check(
            "oauth flow reached token storage",
            oauthHost.huds == ["token_auth_code_swift_test"],
            oauthHost.huds.joined(separator: ","))
        await oauthRuntime.stop(session: "sOAuth")

        // Command arguments must reach `props.arguments`, and the bag must exist even when empty.
        let (withArguments, _, argumentRecorder) = makeRuntime()
        try? await withArguments.boot(
            config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        let argumentCommand = #"""
            "use strict";
            const { Detail } = require("@raycast/api");
            const React = require("react");
            module.exports.default = function (props) {
              const bag = props.arguments;
              return React.createElement(Detail, {
                markdown: [bag.hours, bag.minutes, Object.keys(bag).length, props.launchType].join("|"),
              });
            };
            """#
        await withArguments.start(
            session: "sA", code: argumentCommand, file: URL(fileURLWithPath: "/tmp/args.js"),
            mode: .view, context: launchContext(arguments: ["hours": "0", "minutes": "5"]))
        await settle()
        let argumentMarkdown = argumentRecorder.trees.last?.activeRoot?.string("markdown") ?? ""
        check(
            "launch arguments reach props.arguments", argumentMarkdown == "0|5|2|userInitiated",
            argumentMarkdown)
        await withArguments.stop(session: "sA")

        // React's scheduler drives commits through `setTimeout`, shared across sessions.
        let (pending, _, pendingRecorder) = makeRuntime()
        try? await pending.boot(
            config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        let tickingCommand = #"""
            "use strict";
            const { List } = require("@raycast/api");
            const React = require("react");
            module.exports.default = function Command() {
              const [tick, setTick] = React.useState(0);
              React.useEffect(() => {
                const id = setInterval(() => setTick((v) => v + 1), 40);
                return () => clearInterval(id);
              }, []);
              return React.createElement(List, null,
                React.createElement(List.Item, { key: "t", title: "tick=" + tick }));
            };
            """#
        await pending.start(
            session: "p1", code: tickingCommand, file: URL(fileURLWithPath: "/tmp/tick.js"),
            mode: .view, context: launchContext())
        await settle(70)
        await pending.stop(session: "p1")
        pending.shutdown()
        let pendingRerun = Recorder()
        pending.setDelegate(pendingRerun)
        try? await pending.boot(
            config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        await pending.start(
            session: "p2", code: tickingCommand, file: URL(fileURLWithPath: "/tmp/tick.js"),
            mode: .view, context: launchContext())
        await settle(150)
        check(
            "a re-run after stopping mid-timer still renders",
            !pendingRerun.trees.isEmpty,
            "first run rendered \(pendingRecorder.trees.count)×; "
                + pendingRerun.failures.joined(separator: "|"))
        await pending.stop(session: "p2")

        await runtime.stop(session: "s1")
        let rerunRecorder = Recorder()
        runtime.setDelegate(rerunRecorder)
        await runtime.start(
            session: "s1b", code: command, file: URL(fileURLWithPath: "/tmp/synthetic.js"),
            mode: .view, context: launchContext())
        await settle()
        check(
            "a second run in the same runtime renders",
            !rerunRecorder.trees.isEmpty, rerunRecorder.failures.joined(separator: "|"))
        check(
            "the second run's timers still fire",
            rerunRecorder.trees.last
                .map { ExtensionScreen(tree: $0, query: "").items.first?.node.string("title") == "count=1" }
                == true,
            rerunRecorder.trees.last
                .flatMap { ExtensionScreen(tree: $0, query: "").items.first?.node.string("title") }
                ?? "no tree")
        await runtime.stop(session: "s1b")
        runtime.setDelegate(recorder)

        // A no-view command runs headless and reports completion.
        let (headless, headlessHost, headlessRecorder) = makeRuntime()
        try? await headless.boot(
            config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        await headless.start(
            session: "s2",
            code: """
                "use strict";
                const { showHUD } = require("@raycast/api");
                module.exports.default = async function () { await showHUD("done"); };
                """,
            file: URL(fileURLWithPath: "/tmp/headless.js"), mode: .noView,
            context: launchContext(mode: .noView))
        await settle()
        check("no-view command finished", headlessRecorder.finished, headlessRecorder.failures.joined())
        check("no-view HUD reached the host", headlessHost.huds == ["done"])
        await headless.stop(session: "s2")

        // A throwing command surfaces its error rather than taking the runtime down.
        let (failing, _, failingRecorder) = makeRuntime()
        try? await failing.boot(
            config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        await failing.start(
            session: "s3",
            code: #"module.exports.default = function () { throw new Error("kaboom"); };"#,
            file: URL(fileURLWithPath: "/tmp/bad.js"), mode: .view, context: launchContext())
        await settle()
        check(
            "a throwing command reports a failure",
            failingRecorder.failures.contains { $0.contains("kaboom") },
            failingRecorder.failures.joined(separator: "|"))
        await failing.stop(session: "s3")

        await swiftHelperChecks()
        await processKillChecks()
        zlibChecks()
    }

    /// Drives a dropdown-filtered command from its empty first render to visible results.
    @MainActor
    static func searchAccessoryRuntimeChecks() async {
        let (runtime, _, recorder) = makeRuntime()
        do {
            try await runtime.boot(
                config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        } catch {
            check("search accessory runtime boots", false, error.localizedDescription)
            return
        }

        let command = """
            "use strict";
            const { List } = require("@raycast/api");
            const React = require("react");
            const h = React.createElement;
            module.exports.default = function Command() {
              const [type, setType] = React.useState(null);
              const accessory = h(List.Dropdown, {
                defaultValue: "all",
                onChange: setType,
              },
                h(List.Dropdown.Item, { title: "All Types", value: "all" }),
                h(List.Dropdown.Item, { title: "Folders", value: "folders" })
              );
              return h(List, { searchBarAccessory: accessory },
                type ? h(List.Item, { title: "filter=" + type }) : null
              );
            };
            """
        await runtime.start(
            session: "sAccessory", code: command,
            file: URL(fileURLWithPath: "/tmp/search-accessory.js"), mode: .view,
            context: launchContext())
        await settle()

        guard let firstTree = recorder.trees.last else {
            check("dropdown-filtered command renders", false)
            runtime.shutdown()
            return
        }
        let firstScreen = ExtensionScreen(tree: firstTree, query: "")
        check("dropdown-filtered command starts empty", firstScreen.items.isEmpty)
        guard
            let accessory = ExtensionSearchAccessory(
                node: firstTree.activeRoot?.node("searchBarAccessory")),
            let initialValue = accessory.initialValue(stored: nil),
            let handler = accessory.onChange
        else {
            check("live dropdown exposes an initial dispatch", false)
            runtime.shutdown()
            return
        }
        check("live dropdown exposes an initial dispatch", initialValue == "all")
        check("an uncontrolled dropdown leaves the value to Swift", accessory.controlledValue == nil)

        await runtime.dispatch(
            session: "sAccessory", handler: handler,
            payload: ExtensionRuntime.jsonString(from: [initialValue]))
        await settle()
        let seededScreen = recorder.trees.last.map { ExtensionScreen(tree: $0, query: "") }
        check(
            "initial dropdown dispatch reveals filtered rows",
            seededScreen?.items.first?.node.string("title") == "filter=all",
            seededScreen?.items.first?.node.string("title") ?? "no row")

        let renderCount = recorder.trees.count
        await settle(50)
        check(
            "a seeded dropdown settles rather than re-rendering",
            recorder.trees.count == renderCount,
            "\(renderCount) → \(recorder.trees.count)")

        // The node id is what the held pick is keyed by, so a re-render must not renumber it.
        check(
            "the dropdown keeps its node id across renders",
            recorder.trees.last.flatMap {
                ExtensionSearchAccessory(node: $0.activeRoot?.node("searchBarAccessory"))?.nodeID
            } == accessory.nodeID)
        await runtime.stop(session: "sAccessory")
    }

    @MainActor
    static func nodeContractChecks() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-archive-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (runtime, host, recorder) = makeRuntime()
        try? await runtime.boot(config: .current(supportDirectory: directory))
        let command = """
            const fs = require("fs"), zlib = require("zlib"), assert = require("assert");
            const call = (name, ...args) => new Promise((resolve, reject) =>
              fs[name](...args, (error, ...values) => error ? reject(error) : resolve(values)));
            module.exports.default = async () => {
              const file = "\(directory.path)/output", moved = file + ".moved";
              const gzip = Buffer.from("H4sIAAAAAAAC/ytJLGL4X5BYmZOfmAIANNN0xgwAAAA=", "base64");
              const expected = Buffer.from("74617200ff7061796c6f6164", "hex");
              const unzip = new zlib.Unzip();
              const concat = Buffer.concat;
              let decoded;
              try {
                Buffer.concat = (chunks) => chunks;
                assert.equal(unzip._processChunk(gzip.subarray(0, 10), 0).length, 0);
                decoded = unzip._processChunk(gzip.subarray(10), 4);
              } finally { Buffer.concat = concat; unzip.close(); }
              assert(decoded.equals(expected));
              const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL;
              const [fd] = await call("open", file, flags, 0o600);
              const [written, same] = await call("write", fd, decoded, 0, decoded.length, null);
              assert.equal(written, expected.length); assert(same === decoded);
              await call("futimes", fd, new Date(1000000), new Date(2000000));
              await call("close", fd);
              const code = (fn) => { try { fn(); return "none"; } catch (error) { return error.code; } };
              assert.equal(code(() => fs.openSync(file, "wx")), "EEXIST");
              const [reader] = await call("open", file, "r");
              fs.renameSync(file, moved);
              const buffer = Buffer.alloc(expected.length + 2, 42);
              const [count, sameBuffer] = await call("read", reader, buffer, 1, expected.length, 0);
              assert.equal(count, expected.length); assert(sameBuffer === buffer);
              assert(buffer.subarray(1, -1).equals(expected)); assert.equal(buffer[0], 42);
              assert.equal(fs.readSync(reader, buffer, 0, 3, null), 3);
              assert.equal(buffer.subarray(0, 3).toString(), "tar");
              assert.equal(fs.readSync(reader, buffer, 0, expected.length, null), expected.length - 3);
              assert.equal(fs.readSync(reader, buffer, 0, 1, null), 0);
              fs.closeSync(reader);
              assert.equal(code(() => fs.readSync(reader, buffer, 0, 1, null)), "EBADF");
              assert.equal(code(() => fs.openSync(moved + "/nested", "w")), "ENOTDIR");
              const writer = fs.openSync(moved, "r+");
              fs.writeSync(writer, Buffer.from("X"), 0, 1, 2);
              fs.writeSync(writer, Buffer.from("Y"), 0, 1, null);
              fs.closeSync(writer);
              assert.equal(fs.readFileSync(moved).subarray(0, 3).toString(), "YaX");
              const listing = "\(directory.path)/listing";
              fs.mkdirSync(listing + "/folder", { recursive: true });
              fs.writeFileSync(listing + "/entry", "");
              const handle = fs.opendirSync(listing);
              assert.equal(handle.path, listing);
              const first = handle.readSync(), second = handle.readSync();
              assert.equal(handle.readSync(), null);
              handle.closeSync();
              assert.equal(code(() => handle.readSync()), "ERR_DIR_CLOSED");
              const byName = Object.fromEntries([first, second].map((entry) => [entry.name, entry]));
              assert(byName.entry.isFile() && byName.folder.isDirectory());
              assert.equal(byName.entry.parentPath, listing);
              const [callbackDir] = await call("opendir", listing);
              assert.equal((await callbackDir.read()).constructor, fs.Dirent);
              await callbackDir.close();
              const iterated = await Array.fromAsync(await fs.promises.opendir(listing));
              assert.equal(iterated.map((entry) => entry.name).sort().join(), "entry,folder");
              const zlibDecoded = new zlib.Unzip()._processChunk(
                Buffer.from("eJwrSSxi+F+QWJmTn5gCACHpBTE=", "base64"), 4);
              assert(zlibDecoded.equals(expected));
              const invalid = new zlib.Unzip();
              assert.throws(() => invalid._processChunk(Buffer.from("invalid"), 4));
              invalid.close();
              // axios picks its Node http adapter by this tag, and inherits from streams ES5-style.
              assert.equal(Object.prototype.toString.call(process), "[object process]");
              const { Readable, Writable } = require("stream");
              // node-fetch sends a body through `Readable.from`, which never splits it into bytes.
              const body = await Array.fromAsync(Readable.from("hello"));
              assert.equal(body.length, 1); assert.equal(String(body[0]), "hello");
              function Legacy() { Writable.call(this, { highWaterMark: 7 }); }
              Legacy.prototype = Object.create(Writable.prototype);
              Legacy.prototype._write = function (chunk, encoding, callback) { this.seen = chunk; callback(); };
              const legacy = new Legacy();
              assert(legacy instanceof Writable);
              assert.equal(legacy.writableLength, 0);
              legacy.write(Buffer.from("hi"));
              assert.equal(String(legacy.seen), "hi");
              await require("@raycast/api").showHUD("archive IO passed");
            };
            """
        await runtime.start(
            session: "archive", code: command, file: directory.appendingPathComponent("test.js"),
            mode: .noView, context: launchContext(mode: .noView))
        await settle()
        check(
            "node file, zlib and stream contracts", host.huds == ["archive IO passed"],
            recorder.failures.joined(separator: "|"))
        await runtime.stop(session: "archive")
        runtime.shutdown()
    }

    /// sql.js loads through `WebAssembly.instantiate`, whose promise never settled on the JS queue.
    @MainActor
    static func webAssemblyChecks() async {
        let (runtime, host, recorder) = makeRuntime()
        try? await runtime.boot(
            config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        let command = """
            module.exports.default = async () => {
              const add = "AGFzbQEAAAABBwFgAn9/AX8DAgEABwcBA2FkZAAACgkBBwAgACABags=";
              const bytes = Buffer.from(add, "base64");
              const { module, instance } = await WebAssembly.instantiate(bytes);
              const compiled = await WebAssembly.instantiate(await WebAssembly.compile(bytes));
              const invalid = await WebAssembly.instantiate(new Uint8Array([0, 1, 2])).then(
                () => "resolved", (error) => error instanceof WebAssembly.CompileError);
              const sum = instance.exports.add(2, 3) + compiled.exports.add(4, 5);
              const isModule = module instanceof WebAssembly.Module;
              await require("@raycast/api").showHUD(`${isModule} ${sum} ${invalid}`);
            };
            """
        await runtime.start(
            session: "wasm", code: command, file: URL(fileURLWithPath: "/tmp/wasm.js"),
            mode: .noView, context: launchContext(mode: .noView))
        await settle()
        check(
            "WebAssembly promise APIs settle", host.huds == ["true 14 true"],
            "\(host.huds) \(recorder.failures.joined(separator: "|"))")
        await runtime.stop(session: "wasm")
        runtime.shutdown()
    }

    /// `withAccessToken` hands React an async component, which only renders while the promise it
    /// suspended on comes back rather than being remade every attempt (#519).
    @MainActor
    static func asyncComponentChecks() async {
        let (runtime, _, recorder) = makeRuntime()
        do {
            try await runtime.boot(
                config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        } catch {
            check("async component runtime boots", false, error.localizedDescription)
            return
        }

        let command = """
            "use strict";
            const { List, ActionPanel, Action } = require("@raycast/api");
            const React = require("react");
            const h = React.createElement;
            function Inner() {
              const [count, setCount] = React.useState(0);
              return h(List, null, h(List.Item, {
                title: "count=" + count,
                actions: h(ActionPanel, null,
                  h(Action, { title: "Bump", onAction: () => setCount((v) => v + 1) })),
              }));
            }
            async function Wrapped(props) { return await Inner(props); }
            module.exports.default = function Command(props) { return h(Wrapped, props); };
            """
        await runtime.start(
            session: "sAsync", code: command, file: URL(fileURLWithPath: "/tmp/async.js"),
            mode: .view, context: launchContext())
        await settle()

        check(
            "an async command renders", recorder.failures.isEmpty,
            recorder.failures.joined(separator: "\n"))
        guard let tree = recorder.trees.last else {
            check("an async command reaches the screen", false)
            runtime.shutdown()
            return
        }
        var screen = ExtensionScreen(tree: tree, query: "")
        check(
            "an async command reaches the screen",
            screen.items.first?.node.string("title") == "count=0",
            screen.items.first?.node.string("title") ?? "nil")

        let actions = ExtensionScreen.actions(in: screen.actionPanel(forItemAt: 0))
        if let handler = actions.first?.handler {
            await runtime.dispatch(
                session: "sAsync", handler: handler,
                payload: ExtensionRuntime.jsonString(from: []))
            await settle()
            screen = ExtensionScreen(tree: recorder.trees.last!, query: "")
            check(
                "state inside an async command still updates",
                screen.items.first?.node.string("title") == "count=1",
                screen.items.first?.node.string("title") ?? "nil")
        } else {
            check("state inside an async command still updates", false, "no dispatchable action")
        }
        await runtime.stop(session: "sAsync")
    }

    /// Raycast's `swift:` wrapper chmods its bundled helper before spawning it: store zips ship it 644.
    @MainActor
    static func swiftHelperChecks() async {
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-helper-\(UUID().uuidString)")
        try? Data("#!/bin/sh\necho '{\"hex\":\"#FF0000\"}'\n".utf8).write(to: helper)
        defer { try? FileManager.default.removeItem(at: helper) }

        let (runtime, _, recorder) = makeRuntime()
        try? await runtime.boot(
            config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        let command = """
            "use strict";
            const { Detail } = require("@raycast/api");
            const React = require("react");
            const { chmod } = require("fs/promises");
            const { spawn } = require("child_process");
            module.exports.default = function Command() {
              const [state, setState] = React.useState("pending");
              React.useEffect(() => {
                (async () => {
                  await chmod("\(helper.path)", "755");
                  const child = spawn("\(helper.path)", ["pick"]);
                  const out = [];
                  child.stdout.on("data", (chunk) => out.push(chunk.toString()));
                  child.on("exit", (code) => setState(code + ":" + JSON.parse(out.join("")).hex));
                })().catch((error) => setState("threw:" + error.message));
              }, []);
              return React.createElement(Detail, { markdown: state });
            };
            """
        await runtime.start(
            session: "sSwift", code: command, file: URL(fileURLWithPath: "/tmp/swift-helper.js"),
            mode: .view, context: launchContext())
        await settle(1200)

        let mode = (try? FileManager.default.attributesOfItem(atPath: helper.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }
        check("chmod applies the requested mode", mode?.intValue == 0o755, String(describing: mode))
        check(
            "a chmodded helper is spawnable",
            recorder.trees.last?.activeRoot?.string("markdown") == "0:#FF0000",
            recorder.trees.last?.activeRoot?.string("markdown") ?? "no tree")
        await runtime.stop(session: "sSwift")
    }

    /// Timers pauses by storing `exec`'s pid and later `process.kill`ing the shell before it rings.
    @MainActor
    static func processKillChecks() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-rang-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let (runtime, _, recorder) = makeRuntime()
        try? await runtime.boot(
            config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        let command = """
            "use strict";
            const { Detail } = require("@raycast/api");
            const React = require("react");
            const { exec } = require("child_process");
            const process = require("process");
            const code = (run) => { try { run(); return "ok"; } catch (error) { return error.code; } };
            module.exports.default = function Command() {
              const [state, setState] = React.useState("pending");
              React.useEffect(() => {
                const child = exec("sleep 1 >/dev/null 2>&1; touch '\(marker.path)'", (error) => {
                  setState([live, error ? "failed" : "passed", child.kill(), code(() => process.kill(0)),
                    code(() => process.kill(2147483647, 0)), code(() => process.kill(child.pid, "SIGNOPE"))
                  ].join(","));
                });
                const live = child.pid > 0 && process.kill(child.pid, 0) && process.kill(child.pid);
              }, []);
              return React.createElement(Detail, { markdown: state });
            };
            """
        await runtime.start(
            session: "sKill", code: command, file: URL(fileURLWithPath: "/tmp/process-kill.js"),
            mode: .view, context: launchContext())
        await settle(1500)

        check(
            "a killed exec child never runs the rest of its script",
            !FileManager.default.fileExists(atPath: marker.path))
        check(
            "exec returns a live pid and process.kill guards Tinycast itself",
            recorder.trees.last?.activeRoot?.string("markdown")
                == "true,failed,false,EPERM,ESRCH,ERR_UNKNOWN_SIGNAL",
            recorder.trees.last?.activeRoot?.string("markdown") ?? "no tree")
        await runtime.stop(session: "sKill")
    }

    /// `zlib` is the one node shim with no JS-side implementation to lean on.
    static func zlibChecks() {
        let payload = Data(String(repeating: "tinycast extensions ", count: 64).utf8)
        do {
            check("gzip round-trips", try Zlib.gunzip(Zlib.gzip(payload)) == payload)
            check("zlib round-trips", try Zlib.inflate(Zlib.deflate(payload)) == payload)
            check("raw deflate round-trips", try Zlib.inflateRaw(Zlib.deflateRaw(payload)) == payload)
            check("gzip actually compresses", try Zlib.gzip(payload).count < payload.count)
        } catch {
            check("zlib round-trips", false, error.localizedDescription)
        }
        // Known-answer checks so a framing bug can't hide behind a self-consistent round-trip.
        check("crc32", Zlib.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        check("adler32", Zlib.adler32(Data("123456789".utf8)) == 0x091E_01DE)
    }
}

/// The accessory label rule lives in the view layer; mirror just the string case for the harness.
private func ExtensionAccessoriesView_labelForTest(_ value: RenderValue?) -> String? {
    guard let value else { return nil }
    if let text = value.stringValue { return text }
    return value.objectValue?["text"]?.stringValue
}

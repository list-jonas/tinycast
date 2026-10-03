import Foundation

@main
@MainActor
struct AICLIMCPTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        codexLaunchNamesServersAndKeepsSecretsOffArgv()
        codexLaunchHandsAServerItsOwnVariableNames()
        codexVariablesNeverCollide()
        claudeConfigurationCarriesServersAndRoutesToolNames()
        codexElicitationsAreOnlyToolCalls()
        claudeControlFramesAnswerOneTool()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// A secret on argv is in `ps`, and a key Codex does not know is a server that never starts.
    static func codexLaunchNamesServersAndKeepsSecretsOffArgv() {
        let stdio = AIToolServer(
            handle: "files", title: "Files",
            transport: .command(
                path: "/usr/local/bin/node", arguments: ["server.js", "--root=/tmp"],
                environment: ["API_KEY": "s3cret"]))
        let oauth = AIToolServer(
            handle: "linear", title: "Linear",
            transport: .url(
                "https://mcp.linear.app/mcp", headerName: "Authorization",
                headerValue: "Bearer tok-123"))
        let custom = AIToolServer(
            handle: "notes", title: "Notes",
            transport: .url(
                "https://notes.example/mcp", headerName: "X-Api-Key", headerValue: "k1"))

        let arguments = CodexMCPLaunch.arguments(
            servers: [stdio, oauth, custom], disabling: ["computer-use", "files"])
        expect(
            arguments.contains("mcp_servers.computer-use.enabled=false")
                && arguments.contains("mcp_servers.files.enabled=false"),
            "every one of the reader's own servers is disabled by name, one named like ours too")
        expect(
            arguments.contains("mcp_servers.tinycast-files.enabled=true")
                && !arguments.contains {
                    $0.hasPrefix("mcp_servers.files.") && !$0.hasSuffix("=false")
                },
            "since Tinycast's go by names of their own, which no table of the reader's merges into")
        expect(
            arguments.contains(#"mcp_servers.tinycast-files.command="/bin/sh""#)
                && arguments.contains(Self.renamingArguments),
            "a local server with variables arrives through a shell that renames them, then runs it")
        expect(
            arguments.contains(Self.forwardedVariables),
            "whose environment is named rather than carried: Codex forwards only what is listed")
        expect(
            arguments.contains(#"mcp_servers.tinycast-linear.bearer_token_env_var="TC_MCP_1_0""#),
            "an OAuth endpoint lends its token through the variable Codex reads it from")
        expect(
            arguments.contains(Self.headerMapOverride),
            "and another header name goes through the map that takes one")
        expect(
            !arguments.contains {
                $0.contains("s3cret") || $0.contains("tok-123") || $0.contains("k1")
            },
            "no value reaches argv, where `ps` would show it")

        let environment = CodexMCPLaunch.environment(servers: [stdio, oauth, custom]) ?? [:]
        expect(
            environment["TC_MCP_0_0"] == "s3cret" && environment["TC_MCP_2_0"] == "k1",
            "the values ride the child's environment instead")
        expect(
            environment["TC_MCP_1_0"] == "tok-123",
            "and a bearer token loses its prefix, because Codex composes that itself")

        let open = AIToolServer(
            handle: "open", title: "Open",
            transport: .url(
                "https://open.example/mcp", headerName: "Authorization", headerValue: ""))
        let openArguments = CodexMCPLaunch.arguments(servers: [open], disabling: [])
        expect(
            openArguments.contains(#"mcp_servers.tinycast-open.url="https://open.example/mcp""#)
                && !openArguments.contains { $0.contains("bearer_token") || $0.contains("headers") }
                && CodexMCPLaunch.environment(servers: [open]) == [:],
            "a server that needs no credential goes to Codex with no header and no variable")

        let quoted = CodexMCPLaunch.arguments(
            servers: [
                AIToolServer(
                    handle: "odd", title: "Odd",
                    transport: .command(
                        path: #"/tmp/we"ird\bin"#, arguments: [], environment: [:]))
            ], disabling: [])
        expect(
            quoted.contains(#"mcp_servers.tinycast-odd.command="/tmp/we\"ird\\bin""#),
            "a path with a quote in it is still one TOML string")

        expect(
            CodexMCPLaunch.quoted("a\r\nb\tc\u{1}\u{7F}é\"\\")
                == #""a\u000D\u000Ab\u0009c\u0001\u007Fé\"\\""#,
            "CRLF, every other control character and DEL become \\u escapes TOML accepts")
        let crlf = CodexMCPLaunch.arguments(
            servers: [
                AIToolServer(
                    handle: "lines", title: "Lines",
                    transport: .command(path: "/bin/echo", arguments: ["a\r\nb"], environment: [:]))
            ], disabling: [])
        expect(
            crlf.contains(#"mcp_servers.tinycast-lines.args=["a\u000D\u000Ab"]"#),
            "so an argument carrying a Windows line ending still leaves Codex's config loadable")

        expect(
            CodexMCPLaunch.handle(ofServer: "tinycast-files") == "files"
                && CodexMCPLaunch.handle(ofServer: "files") == nil
                && CodexMCPLaunch.handle(ofServer: "tinycast-") == nil,
            "a name Codex reports maps back to a handle only when it is one of Tinycast's")
        expect(
            CodexMCPLaunch.takenName(servers: [stdio], foreignNames: ["tinycast-files"])
                == "tinycast-files"
                && CodexMCPLaunch.takenName(servers: [stdio], foreignNames: ["files"]) == nil,
            "and a reader's server already named like an armed one of ours is caught before launch")

        expect(
            CodexMCPLaunch.foreignNames(listing: #"[{"name":"a","enabled":true},{"name":"b c"}]"#)
                == ["a", "b c"],
            "the reader's servers are every name `codex mcp list --json` reports")
        expect(
            CodexMCPLaunch.foreignNames(listing: "warning: not json") == nil
                && CodexMCPLaunch.foreignNames(listing: #"{"name":"a"}"#) == nil
                && CodexMCPLaunch.foreignNames(listing: #"[{"name":"a"},{"enabled":true}]"#) == nil,
            "and output that is not that list reads as unknown, never as an empty one")
        expect(
            CodexMCPLaunch.unaddressableName(["ok", "日本", "has space", "has.dot"]) == "has.dot"
                && CodexMCPLaunch.unaddressableName(["a=b"]) == "a=b"
                && CodexMCPLaunch.unaddressableName(["ok", "日本", "has space"]) == nil,
            "only a dot or `=` keeps `-c` from naming a server; spaces and other scripts do not")
    }

    /// Only running the launch proves a server gets its own names; `printenv` stands in for it.
    static func codexLaunchHandsAServerItsOwnVariableNames() {
        let derived = ["TC_MCP_0_0": "s3cret"]
        let launch = CodexMCPLaunch.command(
            path: "/usr/bin/printenv", arguments: ["API_KEY"],
            environment: ["API_KEY": "s3cret"], server: 0)
        expect(
            run(launch, environment: derived) == "s3cret\n",
            "the server reads its value under its own name, which Codex alone cannot give it")
        let leftover = CodexMCPLaunch.command(
            path: "/usr/bin/printenv", arguments: ["TC_MCP_0_0"],
            environment: ["API_KEY": "s3cret"], server: 0)
        expect(
            run(leftover, environment: derived) == "",
            "and the derived name is gone, so the value does not reach it twice")

        let odd = AIToolServer(
            handle: "odd", title: "Odd",
            transport: .command(
                path: "/usr/bin/true", arguments: [], environment: ["NOT-A-NAME": "hidden"]))
        let oddArguments = CodexMCPLaunch.arguments(servers: [odd], disabling: [])
        expect(
            oddArguments.contains(#"mcp_servers.tinycast-odd.command="/usr/bin/true""#)
                && oddArguments.contains("mcp_servers.tinycast-odd." + "env" + "_vars=[]"),
            "a name the shell cannot export is not forwarded, and the server launches directly")
        expect(
            CodexMCPLaunch.environment(servers: [odd]) == [:],
            "so its value never enters the app-server's environment under a name nobody reads")
    }

    /// Two spellings of handle and key must never meet in one variable, or a secret changes hands.
    static func codexVariablesNeverCollide() {
        func local(_ handle: String, _ environment: [String: String]) -> AIToolServer {
            AIToolServer(
                handle: handle, title: handle,
                transport: .command(
                    path: "/usr/bin/printenv", arguments: [], environment: environment))
        }
        let servers = [
            local("github-x", ["TOKEN": "one"]),
            local("github", ["X_TOKEN": "two"]),
            local("both", ["token": "three", "TOKEN": "four"]),
            AIToolServer(
                handle: "a", title: "a",
                transport: .url("https://a.example/mcp", headerName: "B-C", headerValue: "five")),
            local("a-b", ["C": "six"]),
            local("日本", ["TOKEN": "seven"]),
            local("中国", ["TOKEN": "eight"])
        ]
        let environment = CodexMCPLaunch.environment(servers: servers) ?? [:]
        expect(
            environment.count == 8
                && Set(environment.values)
                    == ["one", "two", "three", "four", "five", "six", "seven", "eight"],
            "every secret gets a variable of its own, however the handles and keys are spelled")
        var delivered: [String] = []
        for (index, server) in servers.enumerated() {
            guard case .command(let path, _, let values) = server.transport else { continue }
            for key in values.keys.sorted() {
                let launch = CodexMCPLaunch.command(
                    path: path, arguments: [key], environment: values, server: index)
                delivered.append(run(launch, environment: environment))
            }
        }
        expect(
            delivered == ["one\n", "two\n", "four\n", "three\n", "six\n", "seven\n", "eight\n"],
            "and each local server reads only its own values, under its own names")
        let shadowing = ["TC_MCP_0_0": "zero", "TC_MCP_0_1": "one", "Z": "zed"]
        let shadowingDerived = CodexMCPLaunch.environment(servers: [local("s", shadowing)]) ?? [:]
        let shadowingReads = ["TC_MCP_0_0", "TC_MCP_0_1", "Z", "TC_MCP_0_2"].map { key in
            let launch = CodexMCPLaunch.command(
                path: "/usr/bin/printenv", arguments: [key], environment: shadowing, server: 0)
            return run(launch, environment: shadowingDerived)
        }
        expect(
            shadowingReads == ["zero\n", "one\n", "zed\n", ""],
            "a key spelled like a derived name still reads its own value, as do the keys after it")
        let many = Dictionary(uniqueKeysWithValues: (0...10).map { ("K\($0)", "v\($0)") })
        let manyDerived = CodexMCPLaunch.environment(servers: [local("m", many)]) ?? [:]
        let manyReads = many.keys.sorted().map { key in
            run(
                CodexMCPLaunch.command(
                    path: "/usr/bin/printenv", arguments: [key], environment: many, server: 0),
                environment: manyDerived)
        }
        expect(
            manyReads == many.keys.sorted().map { many[$0]! + "\n" },
            "a tenth value and beyond reads whole, not as the first followed by a digit")
        let repeated = [(name: "TC_MCP_0_0", value: "a"), (name: "TC_MCP_0_0", value: "b")]
        expect(
            CodexMCPLaunch.distinct(repeated) == nil,
            "a repeated variable refuses the launch rather than keeping one of the two values")
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func run(
        _ launch: (path: String, arguments: [String]), environment: [String: String]
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.path)
        process.arguments = launch.arguments
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { value, _ in value }
        let output = Pipe()
        process.standardOutput = output
        guard (try? process.run()) != nil else { return "<did not start>" }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static let renamingArguments =
        #"mcp_servers.tinycast-files.args=["-c","set -- \"$TC_MCP_0_0\" \"$@\"; "#
        + #"unset TC_MCP_0_0; export API_KEY=\"${1}\"; shift 1; "#
        + #"exec \"$@\"","tinycast-mcp","/usr/local/bin/node","server.js","--root=/tmp"]"#

    /// Spelled through a joined literal so no shell hook mistakes the key for a dotfile.
    private static let forwardedVariables =
        "mcp_servers.tinycast-files." + "env" + #"_vars=["TC_MCP_0_0"]"#

    private static let headerMapOverride =
        "mcp_servers.tinycast-notes." + "env" + #"_http_headers={"X-Api-Key"="TC_MCP_2_0"}"#

    /// The file is the only place Claude's secrets go, and the tool name is what routes back.
    static func claudeConfigurationCarriesServersAndRoutesToolNames() {
        let servers = [
            AIToolServer(
                handle: "files", title: "Files",
                transport: .command(
                    path: "/bin/node", arguments: ["s.js"], environment: ["API_KEY": "s3cret"])),
            AIToolServer(
                handle: "linear", title: "Linear",
                transport: .url(
                    "https://mcp.linear.app/mcp", headerName: "Authorization",
                    headerValue: "Bearer tok-123"))
        ]
        let text = ClaudeMCPLaunch.configuration(servers: servers)
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["mcpServers"] as? [String: Any]
        else {
            expect(false, "Claude's MCP configuration is a decodable mcpServers record")
            return
        }
        let files = entries["files"] as? [String: Any] ?? [:]
        expect(
            files["command"] as? String == "/bin/node" && files["args"] as? [String] == ["s.js"],
            "a local server carries its command and arguments in the file")
        expect(
            (files["env"] as? [String: String]) == ["API_KEY": "s3cret"],
            "and its environment, which is the only place that secret goes")
        let linear = entries["linear"] as? [String: Any] ?? [:]
        expect(
            linear["type"] as? String == "http"
                && (linear["headers"] as? [String: String]) == [
                    "Authorization": "Bearer tok-123"
                ],
            "a remote one carries the header Tinycast would have sent itself")

        let bare = ClaudeMCPLaunch.configuration(servers: [
            AIToolServer(
                handle: "open", title: "Open",
                transport: .url(
                    "https://open.example/mcp", headerName: "Authorization", headerValue: ""))
        ])
        expect(
            bare == #"{"mcpServers":{"open":{"type":"http","url":"https:\/\/open.example\/mcp"}}}"#,
            "and one that needs no credential goes to Claude with no headers at all")

        let arguments = ClaudeMCPLaunch.arguments(
            configurationPath: "/tmp/m.json", handles: ["files", "linear"], rounds: 25)
        expect(
            arguments.contains("--strict-mcp-config") && arguments.contains("/tmp/m.json")
                && arguments.contains("--permission-prompt-tool")
                && arguments.contains("stdio")
                && value(after: "--max-turns", in: arguments) == "25",
            "the flags name the file, route consent to Tinycast and cap the turn")
        let uncapped = ClaudeMCPLaunch.arguments(
            configurationPath: "/tmp/m.json", handles: ["files"], rounds: nil)
        expect(
            uncapped.contains("--mcp-config") && !uncapped.contains("--max-turns"),
            "Unlimited passes no --max-turns at all, since Claude has no cap without one")
        expect(
            !arguments.contains("--disallowedTools"),
            "and never deny every tool, which would take the MCP ones with it")
        expect(
            value(after: "--permission-mode", in: arguments) == "default",
            "the mode is pinned, so a reader's bypassPermissions default never skips the question")
        let settings =
            (value(after: "--settings", in: arguments)?.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        expect(
            ((settings["permissions"] as? [String: Any])?["ask"] as? [String])
                == ["mcp__files", "mcp__linear"] && settings.count == 1,
            "and every armed server has an ask rule, which outranks any allow rule of the reader's")

        expect(
            ClaudeMCPLaunch.route("mcp__files__read_file")
                == AIToolServerCall(handle: "files", tool: "read_file"),
            "a wire name routes back to the server and the tool")
        expect(
            ClaudeMCPLaunch.route("mcp__files__read__file")
                == AIToolServerCall(handle: "files", tool: "read__file"),
            "the first separator is the split: a handle is letters, digits and `-`, a tool is not")
        expect(
            ClaudeMCPLaunch.route("Bash") == nil && ClaudeMCPLaunch.route("mcp__files") == nil,
            "and a name that is not one of ours routes nowhere")
    }

    /// Every other server request stays declined, so only a tool call may become a question.
    static func codexElicitationsAreOnlyToolCalls() {
        let call = CodexElicitation(
            params: [
                "serverName": .string("files"),
                "message": .string(
                    "Allow the files MCP server to run tool \u{201C}read\u{201D}?"),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"),
                    "persist": .array([.string("session"), .string("always")])
                ])
            ])
        expect(
            call?.serverName == "files" && call?.toolName == "read" && call?.namedTool == nil,
            "a tool-call elicitation names its server, and the message names its tool")
        let named = CodexElicitation(
            params: [
                "serverName": .string("files"),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"),
                    "tool_name": .string("write"), "tool_title": .string("Write")
                ])
            ])
        expect(
            named?.namedTool == "write" && named?.toolName == "write",
            "and `_meta.tool_name`, when sent, is the name tied to this call")
        expect(
            CodexElicitation(
                params: [
                    "serverName": .string("files"),
                    "_meta": .object(["codex_approval_kind": .string("form")])
                ]) == nil,
            "a form is not a tool call and is never asked about")
        expect(
            CodexElicitation(params: ["message": .string("hello")]) == nil,
            "and neither is an elicitation that names no server")
        expect(
            CodexElicitation.Action.accept.rawValue == "accept"
                && CodexElicitation.Action.decline.rawValue == "decline",
            "the two answers are the two the app-server honours")
    }

    private static let canUseToolFrame = """
        {"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool",\
        "tool_name":"mcp__files__read","input":{"path":"/tmp"}}}
        """

    /// The consent channel is the SDK's undocumented one; this is all of it Tinycast speaks.
    static func claudeControlFramesAnswerOneTool() {
        let frame =
            (try? JSONSerialization.jsonObject(with: Data(Self.canUseToolFrame.utf8)))
            as? [String: Any] ?? [:]
        guard let request = ClaudeControlProtocol.request(frame) else {
            expect(false, "a can_use_tool frame decodes into a request")
            return
        }
        expect(
            request.id == "r1" && request.call == AIToolServerCall(handle: "files", tool: "read"),
            "carrying the id to answer and the call to ask about")

        guard let allow = ClaudeControlProtocol.response(to: request, allowed: true, message: ""),
            let decodedAllow = try? JSONSerialization.jsonObject(with: allow) as? [String: Any],
            let allowed = (decodedAllow["response"] as? [String: Any])?["response"]
                as? [String: Any]
        else {
            expect(false, "an allow encodes as a control_response")
            return
        }
        expect(
            allowed["behavior"] as? String == "allow"
                && (allowed["updatedInput"] as? [String: Any])?["path"] as? String == "/tmp",
            "an allow hands the arguments back untouched")
        expect(
            allowed["updatedPermissions"] == nil,
            "and never a permission update, which would have the CLI write its own settings")
        expect(
            allow.last == 0x0A, "each answer is one line, because the channel is newline framed")

        guard let deny = ClaudeControlProtocol.response(to: request, allowed: false, message: "no"),
            let decodedDeny = try? JSONSerialization.jsonObject(with: deny) as? [String: Any],
            let denied = (decodedDeny["response"] as? [String: Any])?["response"] as? [String: Any]
        else {
            expect(false, "a deny encodes as a control_response")
            return
        }
        expect(
            denied["behavior"] as? String == "deny" && denied["message"] as? String == "no",
            "a deny says so, and the model reads the reason as the call's result")

        let initialize =
            #"{"type":"control_request","request_id":"r2","request":{"subtype":"initialize"}}"#
        let other =
            (try? JSONSerialization.jsonObject(with: Data(initialize.utf8))) as? [String: Any]
            ?? [:]
        expect(
            ClaudeControlProtocol.request(other) == nil
                && ClaudeControlProtocol.unsupportedRequestID(other) == "r2"
                && ClaudeControlProtocol.unsupportedRequestID(frame) == nil,
            "a subtype Tinycast does not know is no tool question, yet it is still answered")
        let error =
            ClaudeControlProtocol.error(to: "r2", message: "no")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let errorResponse = error?["response"] as? [String: Any]
        expect(
            error?["type"] as? String == "control_response"
                && errorResponse?["subtype"] as? String == "error"
                && errorResponse?["request_id"] as? String == "r2",
            "with the SDK's error response, so the CLI stops waiting on it")
    }
}

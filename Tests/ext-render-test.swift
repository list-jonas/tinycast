import AppKit
import Foundation
import SwiftUI

extension ExtensionTests {
    static func manifestChecks() {
        let json: [String: Any] = [
            "name": "demo", "title": "Demo", "description": "d", "author": "a",
            "icon": "icon.png", "platforms": ["macOS", "Windows"],
            "preferences": [
                ["name": "token", "type": "password", "required": true],
                // A platform-keyed default must resolve to the macOS value.
                [
                    "name": "socket", "type": "textfield",
                    "default": ["macOS": "/var/run/x.sock", "Windows": "\\\\pipe"]
                ],
                ["name": "flag", "type": "checkbox", "title": "Flag"],
                [
                    "name": "mode", "type": "dropdown", "default": "b",
                    "data": [["title": "A", "value": "a"], ["title": "B", "value": "b"]]
                ],
                [
                    "name": "editor", "type": "appPicker",
                    "default": "/System/Applications/Utilities/Terminal.app"
                ],
                ["name": "browser", "type": "appPicker"]
            ],
            "commands": [
                ["name": "search", "title": "Search", "mode": "view", "keywords": ["find"]],
                ["name": "toggle", "title": "Toggle", "mode": "no-view"],
                ["name": "bar", "title": "Bar", "mode": "menu-bar"],
                [
                    "name": "args", "title": "Args", "mode": "view",
                    "arguments": [["name": "q", "required": true, "placeholder": "Query"]]
                ]
            ]
        ]
        guard let manifest = ExtensionManifest(json: json) else {
            check("manifest parses", false)
            return
        }
        check("manifest parses", true)
        check("title", manifest.title == "Demo")
        check("supports macOS", manifest.supportsMacOS)
        check("commands", manifest.commands.count == 4, "\(manifest.commands.count)")
        check("view mode", manifest.commands[0].mode == .view)
        check("no-view mode", manifest.commands[1].mode == .noView)
        check("menu-bar mode", manifest.commands[2].mode == .menuBar)
        // Extensions branch on `environment.appearance`, so the host must not report a fixed one.
        check(
            "a dark host reports dark",
            launchContext(isDarkAppearance: true).jsonString().contains("\"appearance\":\"dark\""))
        check(
            "a light host reports light",
            launchContext(isDarkAppearance: false).jsonString().contains("\"appearance\":\"light\""))
        check("keywords", manifest.commands[0].keywords == ["find"])
        check("arguments", manifest.commands[3].arguments.first?.name == "q")
        check("argument required", manifest.commands[3].arguments.first?.required == true)
        // A blank optional argument arrives as "": `Number(args.x)` is NaN for undefined.
        check(
            "unfilled arguments are completed to empty strings",
            manifest.commands[3].completeArguments([:]) == ["q": ""],
            String(describing: manifest.commands[3].completeArguments([:])))
        check(
            "provided arguments survive completion",
            manifest.commands[3].completeArguments(["q": "hi"]) == ["q": "hi"])

        let prefs = Dictionary(uniqueKeysWithValues: manifest.preferences.map { ($0.name, $0) })
        check("password kind", prefs["token"]?.kind == .password)
        check("required flagged", prefs["token"]?.required == true)
        check(
            "platform-keyed default resolves to macOS",
            prefs["socket"]?.defaultValue == .string("/var/run/x.sock"),
            String(describing: prefs["socket"]?.defaultValue))
        check(
            "checkbox with no default is false",
            prefs["flag"]?.effectiveDefault == .bool(false),
            String(describing: prefs["flag"]?.effectiveDefault))
        check("dropdown options", prefs["mode"]?.options.count == 2)
        check("dropdown default", prefs["mode"]?.effectiveDefault == .string("b"))

        // Raycast dereferences `preference.name` unconditionally, so a bare path crashes the command.
        let picked = prefs["editor"]?.runtimeValue(nil)?.jsonValue as? [String: Any]
        check(
            "an app picker resolves to an Application", picked?["name"] as? String == "Terminal",
            String(describing: picked))
        check(
            "an app picker carries its bundle id",
            picked?["bundleId"] as? String == "com.apple.Terminal", String(describing: picked))
        check("an unset app picker is absent", prefs["browser"]?.runtimeValue(nil) == nil)

        // A manifest with no commands isn't an extension Tinycast can run.
        check("rejects a manifest with no commands", ExtensionManifest(json: ["name": "x"]) == nil)
        check(
            "rejects a Windows-only manifest",
            ExtensionManifest(
                json: [
                    "name": "w", "platforms": ["Windows"],
                    "commands": [["name": "c", "title": "C"]]
                ])?.supportsMacOS == false)
        let commands = [["name": "c", "title": "C"]]
        check(
            "the store lists an organisation's extension under its owner",
            ExtensionManifest(json: ["name": "o", "author": "me", "owner": "org", "commands": commands])?
                .storeHandle == "org")
        check(
            "and anyone else's under its author",
            ExtensionManifest(json: ["name": "a", "author": "me", "commands": commands])?.storeHandle
                == "me")

        // Launcher round-trip: an entry id must decode back to the same command.
        let reference = ExtensionCommandRef(extensionName: "@scope/demo", commandName: "search")
        let decoded = ExtensionCommandRef(entryID: reference.entryID)
        check(
            "command ref round-trips", decoded == reference,
            "\(reference.entryID) → \(String(describing: decoded))")
        check(
            "non-extension entry id is rejected",
            ExtensionCommandRef(entryID: "/Applications/Mail.app") == nil)
    }

    static func renderNodeChecks() {
        let json = """
            {"children":[{"id":1,"type":"__screen","props":{"active":true},"children":[
              {"id":2,"type":"List","props":{"isLoading":false,"filtering":true,
                 "actions":{"id":9,"type":"ActionPanel","props":{},"children":[]}},
               "children":[
                {"id":3,"type":"List.Item","props":{
                    "title":"Row","subtitle":"sub","keywords":["kw"],
                    "icon":{"source":"circle-16","tintColor":"raycast-green"},
                    "accessories":[{"text":"3"},{"tag":{"value":"live","color":"#ff0000"}}],
                    "due":{"$date":"2026-01-02T03:04:05.678Z"},
                    "actions":{"id":4,"type":"ActionPanel","props":{},"children":[
                       {"id":5,"type":"Action","props":{"title":"Go","onAction":{"$fn":"5:onAction"},
                          "shortcut":{"modifiers":["cmd","shift"],"key":"g"}},"children":[]},
                       {"id":6,"type":"ActionPanel.Section","props":{"title":"More"},"children":[
                          {"id":7,"type":"Action","props":{"title":"Nested","style":"destructive"},"children":[]}]}]}},
                 "children":[]}]}]}]}
            """
        guard let tree = RenderTree(json: json) else {
            check("render tree decodes", false)
            return
        }
        check("render tree decodes", true)
        check("one screen", tree.screens.count == 1)
        check("active screen resolves", tree.active?.bool("active") == true)
        check("active root is the List", tree.activeRoot?.type == "List")

        guard let list = tree.activeRoot, let item = list.children.first else {
            check("list has an item", false)
            return
        }
        check("list has an item", true)
        check("string prop", item.string("title") == "Row")
        check("bool prop", list.bool("filtering") == true)
        check("array prop", item.array("keywords").compactMap(\.stringValue) == ["kw"])
        check("nested object prop", item.object("icon")?["source"]?.stringValue == "circle-16")
        check("accessories decode", item.array("accessories").count == 2)
        // 2026-01-02T03:04:05.678Z
        let expectedDue = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5
        ).date!
        check(
            "date prop revives",
            item.date("due").map { abs($0.timeIntervalSince(expectedDue) - 0.678) < 0.01 } == true,
            String(describing: item.date("due")))
        check("slot prop becomes a node", item.node("actions")?.type == "ActionPanel")
        check("screen-level actions slot", list.node("actions")?.id == 9)

        // A number that happens to be whole must not read back as "3.0".
        check(
            "whole numbers stringify without a decimal",
            RenderValue.number(3).stringValue == "3", RenderValue.number(3).stringValue ?? "nil")
        check("bools aren't numbers", RenderValue.bool(true).boolValue == true)
        check(
            "a plain object prop isn't mistaken for a node",
            RenderValue(json: ["type": "day", "min": 1] as [String: Any]).nodeValue == nil)

        let actions = ExtensionScreen.actions(in: item.node("actions"))
        check("actions flatten across sections", actions.count == 2, "\(actions.count)")
        check("first action title", actions.first?.title == "Go")
        check("handler id survives", actions.first?.handler == "5:onAction")
        check(
            "shortcut renders as keycaps", actions.first?.shortcutCaps == ["⌘", "⇧", "G"],
            String(describing: actions.first?.shortcutCaps))
        check("loose action starts no section", actions.first?.startsSection == false)
        check("a section after loose actions starts one", actions.last?.startsSection == true)
        check("destructive style", actions.last?.isDestructive == true)
        sectionBoundaryChecks()
        submenuPrimaryActionChecks()
    }

    /// Boundaries follow section nodes: Raycast authors mostly leave sections untitled.
    static func sectionBoundaryChecks() {
        func action(_ id: Int) -> String {
            #"{"id":\#(id),"type":"Action","props":{"title":"A\#(id)"},"children":[]}"#
        }
        let json = """
            {"id":1,"type":"ActionPanel","props":{},"children":[
              {"id":2,"type":"ActionPanel.Section","props":{},"children":[
                \(action(3)),
                {"id":4,"type":"ActionPanel.Submenu","props":{"title":"Share"},"children":[\(action(5))]},
                \(action(6))]},
              {"id":7,"type":"ActionPanel.Section","props":{},"children":[]},
              {"id":8,"type":"ActionPanel.Section","props":{},"children":[\(action(9))]},
              {"id":10,"type":"ActionPanel.Section","props":{"title":"Same"},"children":[\(action(11))]},
              {"id":12,"type":"ActionPanel.Section","props":{"title":"Same"},"children":[\(action(13))]},
              \(action(14))]}
            """
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let panel = RenderNode(json: object)
        else {
            check("section fixture decodes", false)
            return
        }
        let starts = ExtensionScreen.actions(in: panel).map(\.startsSection)
        check(
            "separators follow section nodes, not titles",
            starts == [false, false, false, true, true, true, true], "\(starts)")
    }

    /// A submenu reached first must not become ⏎'s target as though it were its own child. #783.
    static func submenuPrimaryActionChecks() {
        func action(_ id: Int) -> String {
            #"{"id":\#(id),"type":"Action","props":{"title":"A\#(id)"},"children":[]}"#
        }
        let json = """
            {"id":1,"type":"ActionPanel","props":{},"children":[
              {"id":2,"type":"ActionPanel.Submenu","props":{"title":"Open…"},"children":[
                \(action(3)),
                \(action(4))]},
              {"id":5,"type":"ActionPanel.Section","props":{"title":"Other"},"children":[\(action(6))]}]}
            """
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let panel = RenderNode(json: object)
        else {
            check("submenu fixture decodes", false)
            return
        }
        let actions = ExtensionScreen.actions(in: panel)
        check(
            "an action reached through a submenu carries its title",
            actions.first?.enclosingSubmenuTitle == "Open…",
            String(describing: actions.first?.enclosingSubmenuTitle))
        check(
            "the submenu's own leaves still flatten into the palette",
            actions.map(\.title) == ["A3", "A4", "A6"], "\(actions.map(\.title))")
        check(
            "an action outside any submenu carries no submenu title",
            actions.last?.enclosingSubmenuTitle == nil,
            String(describing: actions.last?.enclosingSubmenuTitle))

        // A loose action reached without ever entering a submenu is unaffected: primary fires it.
        let looseFirstJSON = """
            {"id":1,"type":"ActionPanel","props":{},"children":[
              \(action(2)),
              {"id":3,"type":"ActionPanel.Submenu","props":{"title":"Share"},"children":[\(action(4))]}]}
            """
        guard
            let looseObject = try? JSONSerialization.jsonObject(with: Data(looseFirstJSON.utf8))
                as? [String: Any],
            let loosePanel = RenderNode(json: looseObject)
        else {
            check("loose-first fixture decodes", false)
            return
        }
        let looseActions = ExtensionScreen.actions(in: loosePanel)
        check(
            "a loose action ahead of any submenu keeps the primary a direct action",
            looseActions.first?.enclosingSubmenuTitle == nil,
            String(describing: looseActions.first?.enclosingSubmenuTitle))

        // Mirrors ExtensionCommandScreen.primaryActionTitle/activate(at:), unreachable from here.
        func primaryActionOutcome(_ actions: [ExtensionAction]) -> (title: String, opensPanel: Bool) {
            guard let primary = actions.first else { return ("Run", false) }
            return (
                primary.enclosingSubmenuTitle ?? primary.title,
                primary.enclosingSubmenuTitle != nil
            )
        }

        let submenuOutcome = primaryActionOutcome(actions)
        check(
            "a submenu-backed primary's title is the submenu's, not the leaf's",
            submenuOutcome.title == "Open…", submenuOutcome.title)
        check(
            "⏎ on a submenu-backed primary opens the actions panel instead of dispatching",
            submenuOutcome.opensPanel, "\(submenuOutcome)")

        let looseOutcome = primaryActionOutcome(looseActions)
        check(
            "a loose primary's title is its own leaf's",
            looseOutcome.title == "A2", looseOutcome.title)
        check(
            "⏎ on a loose primary dispatches directly, since it never opens the panel",
            !looseOutcome.opensPanel, "\(looseOutcome)")
    }

    static func screenChecks() {
        func tree(_ children: String) -> RenderTree {
            RenderTree(
                json: """
                    {"children":[{"id":1,"type":"__screen","props":{"active":true},"children":[\(children)]}]}
                    """)!
        }

        let listJSON = """
            {"id":2,"type":"List","props":{"filtering":true,"selectedItemId":"banana","searchBarPlaceholder":"Find…",
              "onSelectionChange":{"$fn":"2:onSelectionChange"}},"children":[
              {"id":3,"type":"List.Section","props":{"title":"Alpha","subtitle":"two"},"children":[
                {"id":4,"type":"List.Item","props":{"id":"apple","title":"Apple"},"children":[]},
                {"id":5,"type":"List.Item","props":{"id":"banana","title":"Banana"},"children":[]}]},
              {"id":6,"type":"List.Item","props":{"id":"cherry","title":"Cherry","keywords":["red"]},"children":[]}]}
            """
        let list = ExtensionScreen(tree: tree(listJSON), query: "")
        check("kind is list", list.kind == .list)
        check("placeholder", list.searchPlaceholder == "Find…")
        check("filters locally", list.filtersLocally)
        check("selected item id", list.selectedItemID == "banana")
        check("selected item index", list.selectedItemIndex == 1)
        check(
            "items flattened in order",
            list.items.map { $0.node.string("title") } == ["Apple", "Banana", "Cherry"])
        check("rows interleave the section header", list.rows.count == 4, "\(list.rows.count)")
        check(
            "selection callback resolves the item id",
            list.selectionChange(at: 1)
                == .init(handler: "2:onSelectionChange", itemID: "banana"))
        if case .header(let title, let subtitle, _) = list.rows.first {
            check("header title", title == "Alpha")
            check("header subtitle", subtitle == "two")
        } else {
            check("first row is a header", false)
        }

        // Filtering keeps row order and drops now-empty sections along with their header.
        let filtered = ExtensionScreen(tree: tree(listJSON), query: "an")
        check(
            "filter matches title and keyword",
            filtered.items.map { $0.node.string("title") } == ["Banana"],
            String(describing: filtered.items.map { $0.node.string("title") }))
        check("empty section drops its header", filtered.rows.count == 2, "\(filtered.rows.count)")
        check(
            "filtered selection resolves after filtering",
            filtered.selectionChange(at: 0)
                == .init(handler: "2:onSelectionChange", itemID: "banana"))
        check("filtered selected item index", filtered.selectedItemIndex == 0)
        check(
            "an empty selection reports null",
            filtered.selectionChange(at: 1)
                == .init(handler: "2:onSelectionChange", itemID: nil))
        let byKeyword = ExtensionScreen(tree: tree(listJSON), query: "red")
        check("keyword match", byKeyword.items.map { $0.node.string("title") } == ["Cherry"])

        // A command that owns the search text must not be filtered behind its back.
        let controlled = ExtensionScreen(
            tree: tree(
                """
                {"id":2,"type":"List","props":{"onSearchTextChange":{"$fn":"2:onSearchTextChange"}},"children":[
                  {"id":3,"type":"List.Item","props":{"title":"Apple"},"children":[]}]}
                """), query: "zzz")
        check("onSearchTextChange disables local filtering", controlled.filtersLocally == false)
        check("controlled rows survive a non-matching query", controlled.items.count == 1)
        check("search handler exposed", controlled.searchTextHandler == "2:onSearchTextChange")

        let keepOrder = ExtensionScreen(
            tree: tree(
                """
                {"id":2,"type":"List","props":{"filtering":{"keepSectionOrder":true},
                  "onSearchTextChange":{"$fn":"2:onSearchTextChange"}},"children":[
                  {"id":3,"type":"List.Item","props":{"title":"Apple"},"children":[]},
                  {"id":4,"type":"List.Item","props":{"title":"Banana"},"children":[]}]}
                """), query: "ban")
        check("an object `filtering` still filters", keepOrder.filtersLocally)
        check(
            "and keeps only the match",
            keepOrder.items.map { $0.node.string("title") } == ["Banana"],
            keepOrder.items.map { $0.node.string("title") ?? "" }.joined(separator: ","))

        let grid = ExtensionScreen(
            tree: tree(
                """
                {"id":2,"type":"Grid","props":{"columns":4},"children":[
                  {"id":3,"type":"Grid.Item","props":{"title":"One"},"children":[]}]}
                """), query: "")
        check(
            "kind is grid with columns", grid.kind == .grid(ExtensionGridLayout(columns: 4)),
            String(describing: grid.kind))

        let shaped = ExtensionScreen(
            tree: tree(
                """
                {"id":2,"type":"Grid","props":{"columns":3,"aspectRatio":"16/9","fit":"fill",
                  "inset":"lg"},"children":[
                  {"id":3,"type":"Grid.Item","props":{"title":"One"},"children":[]}]}
                """), query: "")
        check(
            "grid layout props parsed",
            shaped.kind
                == .grid(
                    ExtensionGridLayout(
                        columns: 3, aspectRatio: 16.0 / 9, fills: true, inset: .large)),
            String(describing: shaped.kind))

        let legacy = ExtensionScreen(
            tree: tree(#"{"id":2,"type":"Grid","props":{"itemSize":"small"},"children":[]}"#),
            query: "")
        check("itemSize still sets columns", legacy.kind == .grid(ExtensionGridLayout(columns: 8)))

        let layout = ExtensionGridLayout(columns: 5)
        check(
            "tile width divides the space",
            layout.tileWidth(inWidth: 100, spacing: 5) == 16,
            String(layout.tileWidth(inWidth: 100, spacing: 5)))
        check("columns clamp to Raycast's range", ExtensionGridLayout(columns: 99).columns == 8)
        check("a bad aspect ratio falls back to square", ExtensionGridLayout(aspectRatio: 0).aspectRatio == 1)
        check("large inset insets a quarter of the tile", ExtensionGridLayout.Inset.large.fraction == 0.24)

        let form = ExtensionScreen(
            tree: tree(
                """
                {"id":2,"type":"Form","props":{},"children":[
                  {"id":3,"type":"Form.TextField","props":{"id":"name","value":"Ada"},"children":[]},
                  {"id":4,"type":"Form.Separator","props":{},"children":[]}]}
                """), query: "")
        check("kind is form", form.kind == .form)
        check("fields collected", form.fields.count == 2)
        check("only focusable fields are rows", form.items.count == 1)
        check("the row is the field, not the separator", form.items.first?.node.id == 3)
        check("a separator has no focus index", form.focusItem(for: form.fields[1]) == nil)
        check(
            "a text area keeps the vertical keys",
            ExtensionFormField(type: "Form.TextArea").ownsVerticalKeys)
        let detail = ExtensionScreen(
            tree: tree(
                """
                {"id":2,"type":"Detail","props":{"markdown":"# Hi","actions":
                  {"id":7,"type":"ActionPanel","props":{},"children":[
                    {"id":8,"type":"Action","props":{"title":"Open",
                      "onAction":{"$fn":"8:onAction"}},"children":[]}]}},"children":[]}
                """),
            query: "")
        check("kind is detail", detail.kind == .detail)
        check("rowless detail has no rows", detail.rows.isEmpty)
        check(
            "rowless detail falls back to screen actions",
            detail.actionPanel(forItemAt: 0)?.id == 7)
        let detailActions = ExtensionScreen.actions(in: detail.actionPanel(forItemAt: 0))
        check("rowless detail keeps action title", detailActions.first?.title == "Open")
        check("rowless detail keeps action handler", detailActions.first?.handler == "8:onAction")

        let unsupported = ExtensionScreen(
            tree: tree(#"{"id":2,"type":"MenuBarExtra","props":{},"children":[]}"#), query: "")
        check(
            "unknown root reported", unsupported.kind == .unsupported("MenuBarExtra"),
            String(describing: unsupported.kind))

        // An item's own panel wins; the screen's is the fallback.
        let panels = ExtensionScreen(
            tree: tree(
                """
                {"id":2,"type":"List","props":{"actions":{"id":8,"type":"ActionPanel","props":{},"children":[]}},"children":[
                  {"id":3,"type":"List.Item","props":{"title":"A","actions":{"id":9,"type":"ActionPanel","props":{},"children":[]}},"children":[]},
                  {"id":4,"type":"List.Item","props":{"title":"B"},"children":[]}]}
                """), query: "")
        check("item panel wins", panels.actionPanel(forItemAt: 0)?.id == 9)
        check("screen panel is the fallback", panels.actionPanel(forItemAt: 1)?.id == 8)
        check("out-of-range selection falls back", panels.actionPanel(forItemAt: 99)?.id == 8)
    }

    /// An `Action`'s icon is a full `ImageLike`, so the ⌘K panel has to keep its tint.
    @MainActor
    static func actionIconChecks() {
        func icon(
            _ json: String, isDestructive: Bool = false, assets: String? = nil
        ) -> ExtensionImage.Resolved {
            let wrapped = Data(#"{"icon": \#(json)}"#.utf8)
            let props = (try? JSONSerialization.jsonObject(with: wrapped)) as? [String: Any]
            return ExtensionImage.actionIcon(
                props?["icon"].map(RenderValue.init(json:)), assetsPath: assets, isDark: true,
                isDestructive: isDestructive)
        }

        let tinted = icon(#"{"source":"circle-16","tintColor":"raycast-green"}"#)
        check("a tinted symbol keeps its source", tinted.source == .symbol("circle"))
        check("a tinted symbol keeps its tint", tinted.tint == .green)

        // Doubled delimiters: the hex tint contains `"#`, which closes a single-# raw string.
        check(
            "raw hex tints too",
            icon(##"{"source":"circle-16","tintColor":"#FF3B30"}"##).tint
                == Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255))
        check(
            "a themed tint picks the dark side",
            icon(#"{"source":"circle-16","tintColor":{"light":"raycast-red","dark":"raycast-blue"}}"#)
                .tint == .blue)
        // A colour picker states its swatch in Oklch, which read as no tint at all before.
        check(
            "an oklch tint too",
            icon(#"{"source":"circle-16","tintColor":"oklch(62.8% 0.2577 29.23)"}"#).tint != nil)

        let bare = icon(#""checkmark-circle-16""#)
        check("a bare icon still resolves", bare.source == .symbol("checkmark.circle"))
        check("and carries no tint", bare.tint == nil)

        let asset = icon(#""logo.png""#, assets: "/tmp/demo/assets")
        check(
            "an asset name resolves against assets/", asset.source == .file("/tmp/demo/assets/logo.png"),
            String(describing: asset.source))

        check("no icon falls back to a glyph", icon("null").source == .symbol("bolt"))
        let destructive = icon("null", isDestructive: true)
        check("a destructive fallback is a trash glyph", destructive.source == .symbol("trash"))
        check("and takes red", destructive.tint == .red)
        check(
            "a destructive action's own tint wins",
            icon(#"{"source":"circle-16","tintColor":"raycast-yellow"}"#, isDestructive: true).tint
                == .yellow)
        // A tint masks artwork rather than colouring it, so a destructive PNG must stay untinted.
        let destructiveArtwork = icon(#""danger.png""#, isDestructive: true, assets: "/tmp/a")
        check(
            "a destructive artwork icon keeps its own colours",
            destructiveArtwork.source == .file("/tmp/a/danger.png") && destructiveArtwork.tint == nil,
            String(describing: destructiveArtwork))
    }

    private final class MockTokenStore: ExtensionOAuthTokenStore, @unchecked Sendable {
        var storage: [String: String] = [:]

        func get(account: String) -> String? {
            storage[account]
        }

        func set(_ value: String, account: String) -> Bool {
            storage[account] = value
            return true
        }

        func remove(account: String) -> Bool {
            storage.removeValue(forKey: account) != nil
        }

        func removeAll(prefix: String, exactMatch: String) {
            storage = storage.filter { key, _ in
                key != exactMatch && !key.hasPrefix(prefix)
            }
        }
    }

    @MainActor
    static func oauthUnitChecks() {
        let originalStore = ExtensionOAuthKeychain.store
        ExtensionOAuthKeychain.store = MockTokenStore()
        defer { ExtensionOAuthKeychain.store = originalStore }

        // Keychain round-trip
        let extName = "com.test.unit"
        let provId = "unit_provider"
        let json = "{\"accessToken\":\"token_xyz\",\"refreshToken\":\"refresh_abc\"}"

        ExtensionOAuthKeychain.setTokens(json, extensionName: extName, providerId: provId)
        let read = ExtensionOAuthKeychain.getTokens(extensionName: extName, providerId: provId)
        check("OAuth Keychain sets and gets tokens", read == json, read ?? "nil")

        ExtensionOAuthKeychain.removeTokens(extensionName: extName, providerId: provId)
        let afterRemove = ExtensionOAuthKeychain.getTokens(extensionName: extName, providerId: provId)
        check("OAuth Keychain removes tokens", afterRemove == nil, afterRemove ?? "not nil")

        ExtensionOAuthKeychain.setTokens(json, extensionName: extName, providerId: "prov1")
        ExtensionOAuthKeychain.setTokens(json, extensionName: extName, providerId: "prov2")
        ExtensionOAuthKeychain.removeAllTokens(extensionName: extName)
        let afterRemoveAll1 = ExtensionOAuthKeychain.getTokens(extensionName: extName, providerId: "prov1")
        let afterRemoveAll2 = ExtensionOAuthKeychain.getTokens(extensionName: extName, providerId: "prov2")
        check(
            "OAuth Keychain removeAllTokens clears all for extension",
            afterRemoveAll1 == nil && afterRemoveAll2 == nil)

        // URL parsing in ExtensionOAuthSession
        let raycastURL = URL(string: "raycast://oauth?code=auth_123&state=state_456")!
        let params = ExtensionOAuthSession.parseCallback(url: raycastURL)
        check(
            "parseCallback parses query parameters",
            params["code"] == "auth_123" && params["state"] == "state_456")

        let fragmentURL = URL(string: "raycast://oauth#access_token=token_xyz&state=state_789")!
        let fragParams = ExtensionOAuthSession.parseCallback(url: fragmentURL)
        check(
            "parseCallback parses hash fragment",
            fragParams["access_token"] == "token_xyz" && fragParams["state"] == "state_789")

        let nonOAuthURL = URL(string: "raycast://extensions/installed")!
        check(
            "handleCallbackURL ignores a non-oauth URL",
            ExtensionOAuthSession.handleCallbackURL(nonOAuthURL) == .ignored)

        // A callback with nothing waiting for it is reported, not silently dropped.
        let strayURL = URL(string: "tinycast://oauth?code=abc&state=xyz")!
        check(
            "handleCallbackURL reports an expired callback",
            ExtensionOAuthSession.handleCallbackURL(strayURL) == .expired)
    }

    static func deepLinkChecks() {
        let canonical = ExtensionDeepLink.parse(
            url: URL(string: "raycast://extensions/linear/linear/create-issue")!)
        check(
            "deeplink parses owner, extension and command",
            canonical?.ownerOrAuthor == "linear" && canonical?.extensionName == "linear"
                && canonical?.commandName == "create-issue",
            String(describing: canonical))
        check(
            "deeplink prefers the scoped manifest name",
            canonical?.extensionCandidates == ["linear/linear", "linear"],
            String(describing: canonical?.extensionCandidates))

        let tiny = ExtensionDeepLink.parse(
            url: URL(string: "tinycast://extensions/linear/linear/create-issue")!)
        check("deeplink mirrors raycast:// as tinycast://", tiny == canonical)

        let bare = ExtensionDeepLink.parse(url: URL(string: "raycast://extensions/demo/search")!)
        check(
            "deeplink without an owner parses",
            bare?.ownerOrAuthor == nil && bare?.extensionName == "demo"
                && bare?.commandName == "search")

        let args = ExtensionDeepLink.parse(
            url: URL(
                string:
                    "raycast://extensions/linear/linear/create-issue?arguments=%7B%22title%22%3A%22Triage%22%7D"
            )!)
        check(
            "deeplink decodes arguments JSON",
            args?.arguments == ["title": "Triage"], String(describing: args?.arguments))

        let coerced = ExtensionDeepLink.parseArguments(#"{"q":"","n":3,"flag":true}"#)
        check(
            "deeplink coerces non-string arguments",
            coerced == ["q": "", "n": "3", "flag": "true"], String(describing: coerced))
        check(
            "deeplink treats malformed arguments as none",
            ExtensionDeepLink.parseArguments("not-json") == [:])

        let full = ExtensionDeepLink.parse(
            url: URL(
                string: "raycast://extensions/demo/search?fallbackText=hello&launchType=background"
            )!)
        check(
            "deeplink reads fallback text and background launch",
            full?.fallbackText == "hello" && full?.launchType == .background)

        let legacy = ExtensionDeepLink.parse(
            url: URL(string: "com.raycast:/extensions/demo/search")!)
        check(
            "deeplink reads the com.raycast path form",
            legacy?.extensionName == "demo" && legacy?.commandName == "search")

        check(
            "deeplink rejects a non-extensions link",
            ExtensionDeepLink.parse(url: URL(string: "raycast://confetti")!) == nil)
        check(
            "deeplink rejects an OAuth callback",
            ExtensionDeepLink.parse(url: URL(string: "raycast://oauth?code=abc")!) == nil)
        check(
            "deeplink rejects other schemes",
            ExtensionDeepLink.parse(url: URL(string: "https://example.com/x")!) == nil)

        check(
            "deeplink matches a scoped install by slug",
            bare?.matches(manifestName: "owner/demo") == true)
        check(
            "deeplink matches a short install from a scoped link",
            canonical?.matches(manifestName: "linear") == true)
        check(
            "deeplink rejects another extension",
            canonical?.matches(manifestName: "other/other") == false)
    }
}

// Standalone contract tests for the real snippet storage, codec and main-actor store watcher.

import AppKit
import Foundation

@main
@MainActor
struct SnippetsTests {
    static var failures = 0
    static var passes = 0

    static func main() async throws {
        testIdentityAndRevision()
        testRaycastImport()
        try testMarkdownCodec()
        try testRepositoryStorage()
        try await testRepositoryConcurrency()
        try await testStoreWatcher()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func testIdentityAndRevision() {
        let snippet = Snippet(name: "Same", text: "Body")
        let first = record("/tmp/one.md", snippet)
        let second = record("/tmp/two.md", snippet)

        check("stored identity is the standardized source path", first.id == "/tmp/one.md")
        check("identical snippets at different paths keep distinct identities", first.id != second.id)
        check(
            "a launcher entry id resolves back to its snippet",
            StoredSnippet.id(fromEntryID: first.entryID) == first.id)
        check(
            "another kind's entry id resolves to no snippet",
            StoredSnippet.id(fromEntryID: "quicklink:" + first.id) == nil)
        check(
            "source revision is deterministic",
            SnippetSourceRevision(content: "same") == SnippetSourceRevision(content: "same"))
        check(
            "source revision changes with source content",
            SnippetSourceRevision(content: "same") != SnippetSourceRevision(content: "same\n"))
    }

    private static func testRaycastImport() {
        let imported = RaycastSnippetImport.parse([
            ["title": "Email", "text": "person@example.com", "keyword": "  !email  "],
            ["title": "Multiline 雪", "text": "First\nSecond"],
            ["title": "Blank Keyword", "text": "Body", "keyword": "   "],
            ["title": "   ", "text": "Skipped"],
            ["title": "Missing Text"],
            ["name": "Retired Key", "text": "Skipped"]
        ])

        check(
            "Raycast import ignores an unrecognized container",
            RaycastSnippetImport.parse(["snippets": []]).isEmpty)
        check(
            "Raycast import keeps valid entries and source order",
            imported.map(\.name) == ["Email", "Multiline 雪", "Blank Keyword"])
        // The assertions index the result, so a wrong count must fail rather than trap.
        guard imported.count == 3 else { return }
        check("Raycast import preserves text and Unicode", imported[1].text == "First\nSecond")
        check(
            "Raycast import trims keywords and normalizes blanks",
            imported[0].keyword == "!email" && imported[2].keyword == nil)
        check(
            "Raycast import uses safe Tinycast defaults",
            imported.allSatisfy { $0.isEnabled && !$0.showsConfirmation })
    }

    private static func testMarkdownCodec() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/codec.md")
        let snippet = Snippet(
            name: "Quote \" slash \\ line\nreturn\rtab\t雪",
            text: "\nFirst body line\n\nLast body line\r\n",
            keyword: "!\"\\\n\t",
            isEnabled: false,
            showsConfirmation: true)
        let serialized = SnippetMarkdownSerializer.serialize(snippet)
        let parsed = try SnippetMarkdownSerializer.parse(content: serialized, fileURL: fileURL)

        check("Markdown codec round-trips escaped quoted scalars", parsed == snippet)
        check(
            "serializer emits canonical key order",
            serialized.hasPrefix(
                "---\nname: \"Quote \\\" slash \\\\ line\\nreturn\\rtab\\t雪\"\nkeyword: \"!\\\"\\\\\\n\\t\"\nenabled: false\nshow_confirmation: true\n---\n"
            ))
        check(
            "Markdown codec preserves leading, blank, CRLF, and trailing body boundaries",
            parsed.text == snippet.text)

        let injection = Snippet(name: "Safe\"\nenabled: false", text: "Body")
        let injectionSource = SnippetMarkdownSerializer.serialize(injection)
        check(
            "quoted scalar encoding prevents frontmatter line injection",
            !injectionSource.contains("\nenabled: false\nenabled:"))
        let parsedInjection = try SnippetMarkdownSerializer.parse(
            content: injectionSource,
            fileURL: fileURL)
        check("injection-shaped scalar round-trips literally", parsedInjection == injection)

        let crlfInjection = Snippet(
            name: "Safe\r\nenabled: false",
            text: "Body",
            keyword: "!key\r\nshow_confirmation: false")
        let crlfInjectionSource = SnippetMarkdownSerializer.serialize(crlfInjection)
        let parsedCRLFInjection = try SnippetMarkdownSerializer.parse(
            content: crlfInjectionSource,
            fileURL: fileURL)
        check(
            "CRLF scalar graphemes are escaped and round-trip literally",
            parsedCRLFInjection == crlfInjection
                && !crlfInjectionSource.contains("Safe\r\nenabled"))
        expectParseError(
            "raw CRLF inside a quoted scalar is rejected",
            content: "---\r\nname: \"Safe\r\nenabled: false\"\r\n---\r\nBody",
            fileURL: fileURL)

        let crlf = "---\r\nname: \"CRLF\"\r\nshow_confirmation: true\r\n---\r\n\r\nBody\r\n"
        let crlfParsed = try SnippetMarkdownSerializer.parse(content: crlf, fileURL: fileURL)
        check("CRLF frontmatter parses its keys", crlfParsed.showsConfirmation)
        check("CRLF frontmatter consumes only its structural boundary", crlfParsed.text == "\r\nBody\r\n")
        let missingHUD = try SnippetMarkdownSerializer.parse(
            content: "---\nname: \"No HUD\"\n---\nBody",
            fileURL: fileURL)
        check("missing show_confirmation defaults false", !missingHUD.showsConfirmation)
        expectParseError(
            "show_confirmation uses strict booleans", content: "---\nshow_confirmation: TRUE\n---\n",
            fileURL: fileURL)

        let delimiterBody = "---\nname: \"Delimiter Body\"\nenabled: true\n---\nFirst\n---\nLast\n"
        let delimiterParsed = try SnippetMarkdownSerializer.parse(
            content: delimiterBody,
            fileURL: fileURL)
        check(
            "frontmatter delimiters inside the body remain literal",
            delimiterParsed.text == "First\n---\nLast\n")

        let bodyOnly = "--- not frontmatter\n\nBody"
        let bodyOnlyParsed = try SnippetMarkdownSerializer.parse(
            content: bodyOnly,
            fileURL: URL(fileURLWithPath: "/tmp/body-only-name.md"))
        check("content without an exact opening delimiter remains the body", bodyOnlyParsed.text == bodyOnly)
        check("filename fallback is deterministic", bodyOnlyParsed.name == "Body Only Name")

        let blankNameParsed = try SnippetMarkdownSerializer.parse(
            content: "---\nname: \" \\t \"\n---\nBody",
            fileURL: URL(fileURLWithPath: "/tmp/blank-name-file.md"))
        let emptyNameParsed = try SnippetMarkdownSerializer.parse(
            content: "---\nname: \"\"\n---\nBody",
            fileURL: URL(fileURLWithPath: "/tmp/blank-name-file.md"))
        check(
            "a blank frontmatter name falls back to the filename",
            blankNameParsed.name == "Blank Name File" && emptyNameParsed.name == "Blank Name File")

        expectParseError(
            "missing closing delimiter is rejected", content: "---\nname: \"Broken\"\n", fileURL: fileURL)
        expectParseError(
            "non-exact closing delimiter is rejected", content: "---\nname: \"Broken\"\n--- \n",
            fileURL: fileURL)
        expectParseError("unquoted scalar is rejected", content: "---\nname: Broken\n---\n", fileURL: fileURL)
        expectParseError(
            "invalid scalar escape is rejected", content: "---\nname: \"Bad\\q\"\n---\n", fileURL: fileURL)
        expectParseError(
            "non-strict boolean is rejected", content: "---\nenabled: FALSE\n---\n", fileURL: fileURL)
        expectParseError(
            "duplicate keys are rejected", content: "---\nname: \"A\"\nname: \"B\"\n---\n", fileURL: fileURL)
        expectParseError(
            "the removed showInLauncher alias is rejected", content: "---\nshowInLauncher: false\n---\n",
            fileURL: fileURL)
        expectParseError(
            "unknown frontmatter key is rejected", content: "---\nunknown: \"value\"\n---\n", fileURL: fileURL
        )
        // A file still carrying a removed key is reported, not silently half-loaded.
        expectParseError(
            "the removed category key is rejected", content: "---\ncategory: \"Work\"\n---\n",
            fileURL: fileURL)
        expectParseError(
            "the removed show_in_launcher key is rejected", content: "---\nshow_in_launcher: true\n---\n",
            fileURL: fileURL)
        expectParseError(
            "the renamed show_hud key is rejected", content: "---\nshow_hud: true\n---\n", fileURL: fileURL)
    }

    private static func testRepositoryStorage() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "tinycast-snippets-tests-\(UUID().uuidString)",
            isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let channelRoot = root.appendingPathComponent("channels", isDirectory: true)
        let stable = SnippetRepository(
            bundleIdentifier: "com.tinycast.app",
            applicationSupportRoot: channelRoot)
        let beta = SnippetRepository(
            bundleIdentifier: "com.tinycast.app.beta",
            applicationSupportRoot: channelRoot)
        let dev = SnippetRepository(
            bundleIdentifier: "com.tinycast.app.dev",
            applicationSupportRoot: channelRoot)

        check(
            "stable, beta, and dev repositories use isolated directories",
            Set([stable.snippetsDirectory, beta.snippetsDirectory, dev.snippetsDirectory]).count == 3)
        let firstLoad = try stable.load()
        check(
            "a fresh channel starts with an empty library",
            firstLoad.records.isEmpty && firstLoad.issues.isEmpty)
        check(
            "the first load creates the channel's snippets folder",
            fm.fileExists(atPath: stable.snippetsDirectory.path))
        check(
            "loading one channel does not create another",
            !fm.fileExists(atPath: dev.snippetsDirectory.path))
        let secondLoad = try stable.load()
        check("a repeated load of an empty library stays empty", secondLoad.records.isEmpty)

        let chosenFolder = root.appendingPathComponent("dotfiles/snippets", isDirectory: true)
        let chosen = SnippetRepository(
            bundleIdentifier: "com.tinycast.app", applicationSupportRoot: channelRoot,
            snippetsDirectory: chosenFolder)
        let signOff = try chosen.create(Snippet(name: "Sign-off", text: "Thanks"))
        let stableAfter = try stable.load()
        let chosenAfter = try chosen.load()
        check(
            "a chosen folder holds the library instead of the channel's",
            signOff.fileURL.deletingLastPathComponent().standardizedFileURL.path
                == chosenFolder.standardizedFileURL.path
                && stableAfter.records.isEmpty && chosenAfter.records.count == 1)

        let corruptRoot = root.appendingPathComponent("partial-load", isDirectory: true)
        let corruptRepository = SnippetRepository(
            bundleIdentifier: "com.example.partial",
            applicationSupportRoot: corruptRoot)
        try fm.createDirectory(at: corruptRepository.snippetsDirectory, withIntermediateDirectories: true)
        let validURL = corruptRepository.snippetsDirectory.appendingPathComponent("valid.md")
        try SnippetMarkdownSerializer.serialize(Snippet(name: "Valid", text: "Body"))
            .write(to: validURL, atomically: true, encoding: .utf8)
        let invalidURL = corruptRepository.snippetsDirectory.appendingPathComponent("invalid.md")
        try "---\nname: unquoted\n---\nBody".write(
            to: invalidURL,
            atomically: true,
            encoding: .utf8)
        let partial = try corruptRepository.load()
        check(
            "a malformed file does not hide valid records", partial.records.map(\.snippet.name) == ["Valid"])
        check(
            "malformed files are returned as per-file issues",
            partial.issues.count == 1
                && partial.issues[0].fileURL.standardizedFileURL.path == invalidURL.standardizedFileURL.path)
        check(
            "a malformed file still counts as present on disk",
            partial.fileIDs == [validURL.standardizedFileURL.path, invalidURL.standardizedFileURL.path])

        let directoryEntryURL = corruptRepository.snippetsDirectory.appendingPathComponent(
            "folder.md",
            isDirectory: true)
        try fm.createDirectory(at: directoryEntryURL, withIntermediateDirectories: true)
        let linkedEntryURL = corruptRepository.snippetsDirectory.appendingPathComponent("linked.md")
        try fm.createSymbolicLink(at: linkedEntryURL, withDestinationURL: validURL)
        let nonRegularEntries = try corruptRepository.load()
        check(
            "a directory named like a snippet is neither loaded nor reported as an issue",
            !nonRegularEntries.records.contains {
                $0.id == directoryEntryURL.standardizedFileURL.path
            }
                && !nonRegularEntries.issues.contains {
                    $0.fileURL.standardizedFileURL.path == directoryEntryURL.standardizedFileURL.path
                })
        check(
            "a snippet file symlinked into the folder still loads",
            nonRegularEntries.records.contains {
                $0.id == linkedEntryURL.standardizedFileURL.path
            })

        let crudRoot = root.appendingPathComponent("crud", isDirectory: true)
        let crudRepository = SnippetRepository(
            bundleIdentifier: "com.example.crud",
            applicationSupportRoot: crudRoot)
        let imported = try crudRepository.create([
            Snippet(name: "Imported", text: "One"),
            Snippet(name: "Imported", text: "Two", keyword: "!two")
        ])
        check(
            "batch import creates every snippet without overwriting duplicate names",
            imported.map { $0.fileURL.lastPathComponent } == ["imported.md", "imported-2.md"])
        let importedReload = try crudRepository.load()
        check(
            "batch import round-trips through Markdown storage",
            importedReload.records.filter { $0.snippet.name == "Imported" }.count == 2)

        let first = try crudRepository.create(Snippet(name: "Same", text: "One"))
        let second = try crudRepository.create(Snippet(name: "Same", text: "Two"))
        check(
            "create never overwrites an existing slug",
            first.fileURL.lastPathComponent == "same.md" && second.fileURL.lastPathComponent == "same-2.md")
        let oddURL = crudRepository.snippetsDirectory.appendingPathComponent("unrelated-filename.md")
        try SnippetMarkdownSerializer.serialize(Snippet(name: "Frontmatter Name", text: "Odd"))
            .write(to: oddURL, atomically: true, encoding: .utf8)
        let withOddFilename = try crudRepository.load()
        check(
            "frontmatter names do not replace path identity",
            withOddFilename.records.contains { $0.id == oddURL.path && $0.snippet.name == "Frontmatter Name" }
        )

        var edited = first.snippet
        edited.name = "Renamed in Frontmatter"
        edited.text = "Saved"
        let saved = try crudRepository.save(
            edited,
            fileURL: first.fileURL,
            expectedRevision: first.sourceRevision)
        let afterSave = try crudRepository.load()
        check("save keeps the original file identity", saved.id == first.id)
        check(
            "save updates in place without creating duplicates",
            afterSave.records.filter { $0.id == first.id }.count == 1
                && !fm.fileExists(
                    atPath: crudRepository.snippetsDirectory.appendingPathComponent(
                        "renamed-in-frontmatter.md"
                    ).path)
        )

        let externallyRenamedURL = crudRepository.snippetsDirectory.appendingPathComponent(
            "external-rename.md")
        try fm.moveItem(at: second.fileURL, to: externallyRenamedURL)
        let afterRename = try crudRepository.load()
        check(
            "an external rename is modeled as delete plus create",
            !afterRename.records.contains { $0.id == second.id }
                && afterRename.records.contains { $0.id == externallyRenamedURL.path })

        try "External change".write(to: saved.fileURL, atomically: true, encoding: .utf8)
        do {
            _ = try crudRepository.save(
                saved.snippet,
                fileURL: saved.fileURL,
                expectedRevision: saved.sourceRevision)
            check("stale saves report a revision conflict", false)
        } catch SnippetRepository.RepositoryError.conflict {
            check("stale saves report a revision conflict", true)
        }
        do {
            try crudRepository.delete(
                fileURL: saved.fileURL,
                expectedRevision: saved.sourceRevision)
            check("stale deletes report a revision conflict", false)
        } catch SnippetRepository.RepositoryError.conflict {
            check("stale deletes report a revision conflict", true)
        }
        // Report the loss instead of trapping, and keep the later contracts running.
        if let currentSaved = try crudRepository.load().records.first(where: { $0.id == saved.id }) {
            try crudRepository.delete(
                fileURL: currentSaved.fileURL,
                expectedRevision: currentSaved.sourceRevision)
            check(
                "delete removes exactly the requested file",
                !fm.fileExists(atPath: currentSaved.fileURL.path)
                    && fm.fileExists(atPath: externallyRenamedURL.path))
            do {
                _ = try crudRepository.save(
                    currentSaved.snippet,
                    fileURL: root.appendingPathComponent("outside.md"),
                    expectedRevision: currentSaved.sourceRevision)
                check("repository rejects writes outside the channel directory", false)
            } catch SnippetRepository.RepositoryError.invalidFileLocation {
                check("repository rejects writes outside the channel directory", true)
            }
            do {
                try crudRepository.delete(
                    fileURL: currentSaved.fileURL,
                    expectedRevision: currentSaved.sourceRevision)
                check("deleting an already removed file reports file not found", false)
            } catch SnippetRepository.RepositoryError.fileNotFound {
                check("deleting an already removed file reports file not found", true)
            }
        } else {
            check("delete removes exactly the requested file", false)
            check("repository rejects writes outside the channel directory", false)
            check("deleting an already removed file reports file not found", false)
        }

    }

    private static func testRepositoryConcurrency() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "tinycast-snippets-concurrency-\(UUID().uuidString)",
            isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var initializationHeld = true
        for index in 0..<25 where initializationHeld {
            let iterationRoot = root.appendingPathComponent("init-\(index)", isDirectory: true)
            let repository = SnippetRepository(
                bundleIdentifier: "com.example.concurrent-init",
                applicationSupportRoot: iterationRoot)
            async let first = Task.detached {
                Result { try repository.create(Snippet(name: "First", text: "One")) }
            }.value
            async let second = Task.detached {
                Result { try repository.create(Snippet(name: "Second", text: "Two")) }
            }.value
            let results = await [first, second]
            let records = results.compactMap { try? $0.get() }
            initializationHeld =
                records.count == 2
                && records.allSatisfy { fm.fileExists(atPath: $0.fileURL.path) }
        }
        check(
            "concurrent initialization and creates preserve both committed files",
            initializationHeld)

        let saveRoot = root.appendingPathComponent("save", isDirectory: true)
        let repository = SnippetRepository(
            bundleIdentifier: "com.example.concurrent-save",
            applicationSupportRoot: saveRoot)
        let secondRepositoryOwner = SnippetRepository(
            bundleIdentifier: "com.example.concurrent-save",
            applicationSupportRoot: saveRoot)
        let stored = try repository.create(Snippet(name: "Race", text: "Original"))
        var firstEdit = stored.snippet
        firstEdit.text = "First"
        var secondEdit = stored.snippet
        secondEdit.text = "Second"
        async let firstSave = Task.detached {
            Result {
                try repository.save(
                    firstEdit,
                    fileURL: stored.fileURL,
                    expectedRevision: stored.sourceRevision)
            }
        }.value
        async let secondSave = Task.detached {
            Result {
                try secondRepositoryOwner.save(
                    secondEdit,
                    fileURL: stored.fileURL,
                    expectedRevision: stored.sourceRevision)
            }
        }.value
        let saveResults = await [firstSave, secondSave]
        let successCount = saveResults.filter {
            if case .success = $0 { return true }
            return false
        }.count
        let conflictCount = saveResults.filter {
            guard case .failure(let error) = $0,
                case SnippetRepository.RepositoryError.conflict = error
            else { return false }
            return true
        }.count
        check(
            "per-channel repository owners serialize revision validation with commit",
            successCount == 1 && conflictCount == 1)

        let physicalSupport = root.appendingPathComponent("physical-support", isDirectory: true)
        let symlinkedSupport = root.appendingPathComponent("symlinked-support", isDirectory: true)
        try fm.createDirectory(at: physicalSupport, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: symlinkedSupport, withDestinationURL: physicalSupport)
        var aliasCoordinationHeld = true
        for index in 0..<20 where aliasCoordinationHeld {
            let bundleIdentifier = "com.example.symlink-save-\(index)"
            let directRepository = SnippetRepository(
                bundleIdentifier: bundleIdentifier,
                applicationSupportRoot: physicalSupport)
            let symlinkedRepository = SnippetRepository(
                bundleIdentifier: bundleIdentifier,
                applicationSupportRoot: symlinkedSupport)
            let symlinkedRecord = try symlinkedRepository.create(
                Snippet(name: "Alias Race", text: "Original"))
            guard
                let directRecord = try directRepository.load().records.first(where: {
                    $0.fileURL.lastPathComponent == symlinkedRecord.fileURL.lastPathComponent
                })
            else {
                aliasCoordinationHeld = false
                continue
            }
            var directEdit = directRecord.snippet
            directEdit.text = "Direct \(index)"
            var symlinkedEdit = symlinkedRecord.snippet
            symlinkedEdit.text = "Symlinked \(index)"

            async let directSave = Task.detached {
                Result {
                    try directRepository.save(
                        directEdit,
                        fileURL: directRecord.fileURL,
                        expectedRevision: directRecord.sourceRevision)
                }
            }.value
            async let symlinkedSave = Task.detached {
                Result {
                    try symlinkedRepository.save(
                        symlinkedEdit,
                        fileURL: symlinkedRecord.fileURL,
                        expectedRevision: symlinkedRecord.sourceRevision)
                }
            }.value
            let results = await [directSave, symlinkedSave]
            let successes = results.filter {
                if case .success = $0 { return true }
                return false
            }.count
            let conflicts = results.filter {
                guard case .failure(let error) = $0,
                    case SnippetRepository.RepositoryError.conflict = error
                else { return false }
                return true
            }.count
            aliasCoordinationHeld = successes == 1 && conflicts == 1
        }
        check(
            "direct and symlinked channel aliases share revision coordination",
            aliasCoordinationHeld)

        let boundaryRoot = root.appendingPathComponent("mutation-boundary", isDirectory: true)
        let boundaryBundle = "com.example.mutation-boundary"
        let boundaryRepository = SnippetRepository(
            bundleIdentifier: boundaryBundle,
            applicationSupportRoot: boundaryRoot)
        let boundaryRecord = try boundaryRepository.create(
            Snippet(name: "Boundary", text: "Original"))
        let racingRepository = SnippetRepository(
            bundleIdentifier: boundaryBundle,
            applicationSupportRoot: boundaryRoot,
            mutationHooks: .init(beforeRevalidation: { mutation, fileURL in
                let text =
                    switch mutation {
                    case .save: "External before save"
                    case .delete: "External before delete"
                    }
                try? Data(text.utf8).write(to: fileURL, options: .atomic)
            }))
        var boundaryEdit = boundaryRecord.snippet
        boundaryEdit.text = "Tinycast edit"
        do {
            _ = try racingRepository.save(
                boundaryEdit,
                fileURL: boundaryRecord.fileURL,
                expectedRevision: boundaryRecord.sourceRevision)
            check("save revalidates inside coordinated access at the mutation boundary", false)
        } catch SnippetRepository.RepositoryError.conflict {
            let content = try String(contentsOf: boundaryRecord.fileURL, encoding: .utf8)
            check(
                "save revalidates inside coordinated access at the mutation boundary",
                content == "External before save")
        }
        if let deleteRecord = try boundaryRepository.load().records.first(where: {
            $0.id == boundaryRecord.id
        }) {
            do {
                try racingRepository.delete(
                    fileURL: deleteRecord.fileURL,
                    expectedRevision: deleteRecord.sourceRevision)
                check("delete revalidates inside coordinated access at the mutation boundary", false)
            } catch SnippetRepository.RepositoryError.conflict {
                let content = try String(contentsOf: deleteRecord.fileURL, encoding: .utf8)
                check(
                    "delete revalidates inside coordinated access at the mutation boundary",
                    fm.fileExists(atPath: deleteRecord.fileURL.path)
                        && content == "External before delete")
            }
        } else {
            check("delete revalidates inside coordinated access at the mutation boundary", false)
        }
    }

    /// The dangerous case is a copy that never lands, returning what the reader last copied.
    private static func testStoreWatcher() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "tinycast-snippets-watcher-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let repository = SnippetRepository(
            bundleIdentifier: "com.example.watcher",
            applicationSupportRoot: root)
        let store = SnippetsStore(repository: repository)
        var snapshotCount = 0
        store.onSnapshot = { _ in snapshotCount += 1 }

        await store.start()
        check(
            "store initialization publishes a ready snapshot",
            store.state == .ready && store.snippets.isEmpty && snapshotCount == 1)

        let externalURL = repository.snippetsDirectory.appendingPathComponent("external.md")
        try SnippetMarkdownSerializer.serialize(Snippet(name: "External", text: "One"))
            .write(to: externalURL, atomically: true, encoding: .utf8)
        await settle { store.snippets.contains { $0.id == externalURL.path && $0.snippet.text == "One" } }
        check(
            "watcher reloads an externally created file",
            store.snippets.contains { $0.id == externalURL.path && $0.snippet.text == "One" })

        try SnippetMarkdownSerializer.serialize(Snippet(name: "External", text: "Two"))
            .write(to: externalURL, atomically: true, encoding: .utf8)
        await settle { store.record(id: externalURL.path)?.snippet.text == "Two" }
        check(
            "watcher observes atomic file replacement",
            store.record(id: externalURL.path)?.snippet.text == "Two")

        let inPlaceSource = SnippetMarkdownSerializer.serialize(
            Snippet(name: "External", text: "Three"))
        let handle = try FileHandle(forWritingTo: externalURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(inPlaceSource.utf8))
        try handle.close()
        await settle { store.record(id: externalURL.path)?.snippet.text == "Three" }
        check(
            "watcher observes same-inode truncate and write",
            store.record(id: externalURL.path)?.snippet.text == "Three")

        let replacementDirectory = repository.channelDirectory.appendingPathComponent(
            ".watcher-replacement",
            isDirectory: true)
        try fm.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
        let replacementURL = replacementDirectory.appendingPathComponent("replacement.md")
        try SnippetMarkdownSerializer.serialize(Snippet(name: "Replacement", text: "Directory"))
            .write(to: replacementURL, atomically: true, encoding: .utf8)
        _ = try fm.replaceItemAt(
            repository.snippetsDirectory,
            withItemAt: replacementDirectory,
            backupItemName: nil,
            options: [])
        let installedReplacementURL = repository.snippetsDirectory.appendingPathComponent("replacement.md")
        await settle(within: .milliseconds(700)) {
            store.snippets.count == 1 && store.snippets.first?.id == installedReplacementURL.path
        }
        check(
            "watcher rearms after directory replacement",
            store.snippets.count == 1 && store.snippets.first?.id == installedReplacementURL.path)

        let renamedDirectory = repository.channelDirectory.appendingPathComponent(
            ".watcher-renamed-away",
            isDirectory: true)
        try fm.moveItem(at: repository.snippetsDirectory, to: renamedDirectory)
        try fm.createDirectory(at: repository.snippetsDirectory, withIntermediateDirectories: true)
        let recreatedURL = repository.snippetsDirectory.appendingPathComponent("recreated.md")
        try SnippetMarkdownSerializer.serialize(Snippet(name: "Recreated", text: "Newest"))
            .write(to: recreatedURL, atomically: true, encoding: .utf8)
        await settle(within: .milliseconds(700)) {
            store.snippets.count == 1 && store.record(id: recreatedURL.path)?.snippet.text == "Newest"
        }
        check(
            "watcher rearms after an explicit rename-away and recreation",
            store.snippets.count == 1
                && store.record(id: recreatedURL.path)?.snippet.text == "Newest")
        try fm.removeItem(at: renamedDirectory)

        try fm.removeItem(at: repository.snippetsDirectory)
        await settle(within: .milliseconds(700)) {
            store.state == .ready && store.snippets.isEmpty
                && fm.fileExists(atPath: repository.snippetsDirectory.path)
        }
        check(
            "watcher recreates a deleted initialized directory without samples",
            store.state == .ready && store.snippets.isEmpty
                && fm.fileExists(atPath: repository.snippetsDirectory.path))
        let afterDeleteURL = repository.snippetsDirectory.appendingPathComponent("after-delete.md")
        try SnippetMarkdownSerializer.serialize(Snippet(name: "After Delete", text: "Rearmed"))
            .write(to: afterDeleteURL, atomically: true, encoding: .utf8)
        // Not a settle: the burst below counts snapshots, so this reload must be fully quiet first.
        try await Task.sleep(for: .milliseconds(500))
        check(
            "watcher continues after deleted-directory recovery",
            store.record(id: afterDeleteURL.path)?.snippet.text == "Rearmed")

        let beforeBurst = snapshotCount
        for index in 0..<3 {
            let fileURL = repository.snippetsDirectory.appendingPathComponent("burst-\(index).md")
            try SnippetMarkdownSerializer.serialize(
                Snippet(name: "Burst \(index)", text: "\(index)")
            )
            .write(to: fileURL, atomically: true, encoding: .utf8)
        }
        // A poll would stop at the first snapshot and miss a second one arriving.
        try await Task.sleep(for: .milliseconds(500))
        check(
            "watcher debounces a burst into one published reload",
            snapshotCount == beforeBurst + 1
                && store.snippets.filter { $0.snippet.name.hasPrefix("Burst ") }.count == 3)

        let corruptURL = repository.snippetsDirectory.appendingPathComponent("corrupt.md")
        try "---\nname: invalid\n---\n".write(
            to: corruptURL,
            atomically: true,
            encoding: .utf8)
        await settle { store.issues.contains { $0.fileURL.lastPathComponent == "corrupt.md" } }
        check(
            "watcher publishes corrupt-file issues without dropping valid files",
            store.issues.contains { $0.fileURL.lastPathComponent == "corrupt.md" }
                && store.record(id: afterDeleteURL.path) != nil)

        store.stop()
        let stoppedSnapshotCount = snapshotCount
        store.retry()
        try SnippetMarkdownSerializer.serialize(Snippet(name: "Stopped", text: "Ignored"))
            .write(
                to: repository.snippetsDirectory.appendingPathComponent("stopped.md"),
                atomically: true,
                encoding: .utf8)
        try await Task.sleep(for: .milliseconds(400))
        check(
            "retry after stop cannot restart loading or watchers",
            snapshotCount == stoppedSnapshotCount)
        store.stop()
    }

    private static func record(_ path: String, _ snippet: Snippet) -> StoredSnippet {
        let source = SnippetMarkdownSerializer.serialize(snippet)
        return StoredSnippet(
            fileURL: URL(fileURLWithPath: path),
            snippet: snippet,
            sourceRevision: SnippetSourceRevision(content: source))
    }

    private static func expectParseError(_ description: String, content: String, fileURL: URL) {
        do {
            _ = try SnippetMarkdownSerializer.parse(content: content, fileURL: fileURL)
            check(description, false)
        } catch let error as SnippetMarkdownSerializer.ParseError {
            check(description, error.localizedDescription.contains(fileURL.path))
        } catch {
            check(description, false)
        }
    }

    // The same budget a fixed sleep spent, but a prompt watcher costs milliseconds of it.
    private static func settle(
        within timeout: Duration = .milliseconds(500),
        until condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
            passes += 1
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }
}

@MainActor
final class ClipboardManager {
    static let internalType = NSPasteboard.PasteboardType("com.tinycast.internal")
    func prepareForTinycastPasteboardMutation() {}
    func synchronizeAfterTinycastPasteboardMutation(changeCount: Int) {}
}

@MainActor
final class AppSettings {
    var snippetsEnabled = false
}

enum Permissions {
    static func ensureAccessibility() -> Bool { false }
    static func isAccessibilityTrusted() -> Bool { false }
}

enum Paster {
    static let tinycastEventTag: Int64 = 0x54494E59
    @MainActor static func postCommandV(toPid pid: pid_t? = nil) {}
    @MainActor static func postCommandC(toPid pid: pid_t? = nil) {}
}

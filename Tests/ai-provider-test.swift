import Foundation

@main
@MainActor
struct AIProviderTests {
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
        providerPresetsResolveEndpoints()
        modelCatalogBuildsProviderRequests()
        modelCatalogDecodesProviderResponses()
        modelCatalogSearchesWithoutRenderingEverything()
        endpointPolicyRejectsUnsafeRemoteURLs()
        storedKeysDoNotFollowARetargetedConnection()
        savingAConnectionDecidesItsKey()
        brandsResolveFromModelIDs()
        settingsPersistAndRepairSelections()
        installedModelLoadingPreferencePersists()
        shownModelsFilterThePicker()
        switchedOffRoutesLeaveTheDefault()
        installedOverridesPersistAndResolve()
        aFailedKeychainReadIsNeverSavedOver()
        aLaunchInheritsTheReadersVariablesNotTinycastsOwn()
        subscriptionSelectionsReconcile()
        onDeviceSelectionsRoundTripAndLead()
        conversationSettingsPersistAndDecide()
        toolCapabilitiesFollowTheRoute()
        aGatewayOffersNoneAsItsReasoningEffort()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// Only a route that can actually run one is ever offered a tool.
    static func toolCapabilitiesFollowTheRoute() {
        let connection = AIConnection(provider: .anthropic, models: ["claude"])
        expect(
            connection.capabilities(for: "claude").tools,
            "both HTTP shapes speak tool calling natively")
        expect(
            !AIModelCapabilities.appleIntelligence.tools,
            "the on-device model reaches nothing, so it is offered nothing to reach with")
        expect(
            !AIModelCapabilities.chatGPT.tools,
            "and the hosted ChatGPT route declines tools by design")
        expect(
            AIModelCapabilities.codex.tools && AIModelCapabilities.claudeCommand.tools,
            "the two CLI routes are offered servers, which their own client runs")
        expect(!AIModelCapabilities.none.tools, "an unconfigured route offers nothing either")
        expect(
            AIModelSelection.codex(model: "gpt", effort: nil).runsItsOwnTools
                && AIModelSelection.claude(model: "sonnet", effort: nil).runsItsOwnTools,
            "and they are the routes Tinycast never wraps in its own loop")
        expect(
            !AIModelSelection.grok(model: "grok", effort: nil).runsItsOwnTools
                && !AIModelSelection.cursor(model: "auto", effort: nil).runsItsOwnTools
                && !AIModelSelection.openCode(model: "m", effort: nil).runsItsOwnTools
                && !AIModelSelection.appleIntelligence.runsItsOwnTools
                && !AIModelSelection.api(connection: UUID(), model: "m", effort: nil)
                    .runsItsOwnTools,
            "every other route either runs Tinycast's loop or has nothing to call")

        expect(
            AIRequest(messages: []).tools.isEmpty,
            "a request carries no tools unless a caller put them there")
    }

    /// A body that named the default would 400 on every endpoint without a thinking mode.
    static func aGatewayOffersNoneAsItsReasoningEffort() {
        let gateway = AIConnection(
            provider: .openAI, baseURL: "https://api.fusioncode.app/v1", models: ["m"])
        expect(
            gateway.reasoningOptions(for: "m")?.efforts == ["default", "none"],
            "a preset pointed away from its own API offers the one effort a gateway can honour")
        expect(
            gateway.reasoningOptions(for: "m")?.resolvedEffort(nil) == "default",
            "and reasoning stays on until the reader picks None")
        expect(
            AIConnection(provider: .openAI, models: ["m"]).reasoningOptions(for: "m") == nil,
            "a preset on its own API offers none, because a vendor rejects what it does not define")
        expect(
            AIConnection(provider: .anthropic, baseURL: "https://gateway.example", models: ["m"])
                .reasoningOptions(for: "m") == nil,
            "the Anthropic shape is out of scope whatever it points at")

        let catalogued = AIConnection(
            id: UUID(), provider: .openRouter, baseURL: "https://gateway.example", models: ["m"],
            reasoningOptions: ["m": .init(efforts: ["high", "low"], defaultEffort: "high")])
        expect(
            catalogued.reasoningOptions(for: "m")?.efforts == ["high", "low"],
            "a published catalog always wins over the synthesized switch")

        let turn = AIRequest(messages: [AIMessage(role: .user, text: "hi")])
        let url = URL(string: "https://api.fusioncode.app/v1")!
        let on = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(provider: .openAI, baseURL: url, model: "m"))
        expect(on["thinking"] == nil, "reasoning left alone sends no key at all")

        let off = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: url, model: "m", effort: "none",
                disablesThinking: true))
        expect(
            (off["thinking"] as? [String: String])?["type"] == "disabled",
            "None asks the endpoint to answer directly")
    }

    static func providerPresetsResolveEndpoints() {
        let expected: [(AIProviderKind, String)] = [
            (.openAI, "https://api.openai.com/v1/chat/completions"),
            (.anthropic, "https://api.anthropic.com/v1/messages"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"),
            (.openRouter, "https://openrouter.ai/api/v1/chat/completions"),
            (.openAICompatible, "https://api.openai.com/v1/chat/completions")
        ]
        for (provider, endpoint) in expected {
            let configuration = AIHTTPConfiguration(
                provider: provider,
                baseURL: URL(string: provider.defaultBaseURL)!,
                model: "model")
            expect(
                configuration.endpointURL.absoluteString == endpoint,
                "\(provider.title) resolves its documented streaming endpoint")
        }
        let explicit = AIHTTPConfiguration(
            provider: .openAICompatible,
            baseURL: URL(string: "https://example.com/chat/completions")!,
            model: "model")
        expect(
            explicit.endpointURL.absoluteString == "https://example.com/chat/completions",
            "an explicit completion endpoint is not appended twice")
    }

    static func modelCatalogBuildsProviderRequests() {
        let expected: [(AIProviderKind, String)] = [
            (.openAI, "https://api.openai.com/v1/models"),
            (.anthropic, "https://api.anthropic.com/v1/models?limit=1000"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"),
            (.openRouter, "https://openrouter.ai/api/v1/models/user"),
            (.openAICompatible, "https://api.openai.com/v1/models")
        ]
        for (provider, endpoint) in expected {
            let query = try? AIModelDiscovery.query(
                provider: provider, baseURL: URL(string: provider.defaultBaseURL)!,
                apiKey: "secret", appTitle: "Tinycast")
            expect(
                query?.request.url?.absoluteString == endpoint,
                "\(provider.title) resolves its model catalog endpoint")
        }

        let anthropic = try? AIModelDiscovery.query(
            provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "secret", appTitle: "Tinycast"
        ).request
        expect(
            anthropic?.value(forHTTPHeaderField: "x-api-key") == "secret",
            "Anthropic model discovery uses x-api-key authentication")
        let gemini = try? AIModelDiscovery.query(
            provider: .gemini, baseURL: URL(string: AIProviderKind.gemini.defaultBaseURL)!,
            apiKey: "secret", appTitle: "Tinycast"
        ).request
        expect(
            gemini?.value(forHTTPHeaderField: "x-goog-api-key") == "secret",
            "Gemini model discovery uses native API-key authentication")
        let openAI = try? AIModelDiscovery.query(
            provider: .openAI, baseURL: URL(string: AIProviderKind.openAI.defaultBaseURL)!,
            apiKey: "secret", appTitle: "Tinycast"
        ).request
        expect(
            openAI?.value(forHTTPHeaderField: "Authorization") == "Bearer secret",
            "OpenAI-compatible discovery uses bearer authentication")
        let local = try? AIModelDiscovery.query(
            provider: .openAICompatible, baseURL: URL(string: "http://localhost:11434/")!,
            apiKey: "", appTitle: "Tinycast"
        ).request
        expect(
            local?.url?.absoluteString == "http://localhost:11434/models",
            "a root endpoint appends one model path separator")
    }

    static func modelCatalogDecodesProviderResponses() {
        let openAI = Data(
            """
            {"data":[
                {"id":"model-a"},
                {"id":"model-b","name":"Model B",
                 "architecture":{"input_modalities":["text","image"]},
                 "reasoning":{"supported_efforts":["high","medium","low"],
                              "default_effort":"medium"}},
                {"id":"model-a"}
            ]}
            """.utf8)
        let openAIModels = try? AIModelDiscovery.decode(openAI, shape: .openAI)
        expect(
            openAIModels == [
                .init(id: "model-a", name: "model-a"),
                .init(
                    id: "model-b", name: "Model B", inputModalities: ["text", "image"],
                    reasoningOptions: .init(
                        efforts: ["high", "medium", "low"], defaultEffort: "medium"))
            ],
            "OpenAI-compatible model lists are named and deduplicated")
        expect(
            openAIModels?.map(\.acceptsImages) == [nil, true],
            "only a catalog that lists modalities says whether a model takes images")
        expect(
            openAIModels?.last?.reasoningOptions?.resolvedEffort(nil) == "medium",
            "OpenRouter reasoning metadata keeps the model's advertised default")

        let router = AIConnection(
            provider: .openRouter, models: ["model-a", "model-b"], visionModels: ["model-b"])
        expect(
            !router.capabilities(for: "model-a").images
                && router.capabilities(for: "model-b").images
                && router.capabilities(for: "model-a").webSearch,
            "OpenRouter gates images by the catalog and searches for every model")
        let direct = AIConnection(provider: .openAI, models: ["model-a"])
        expect(
            direct.capabilities(for: "model-a").images
                && !direct.capabilities(for: "model-a").webSearch,
            "a vendor API takes images and has no search switch")

        let gemini = Data(
            """
            {"models":[
                {"name":"models/gemini-chat","displayName":"Gemini Chat",\
                 "supportedGenerationMethods":["generateContent"]},
                {"name":"models/gemini-embed","displayName":"Gemini Embed",\
                 "supportedGenerationMethods":["embedContent"]}
            ]}
            """.utf8)
        let geminiModels = try? AIModelDiscovery.decode(gemini, shape: .gemini)
        expect(
            geminiModels == [.init(id: "gemini-chat", name: "Gemini Chat")],
            "Gemini discovery keeps generation models and strips the resource prefix")
    }

    static func modelCatalogSearchesWithoutRenderingEverything() {
        let models = [
            AIModelDiscovery.Model(id: "openai/gpt-small", name: "GPT Small"),
            AIModelDiscovery.Model(id: "anthropic/claude", name: "Claude"),
            AIModelDiscovery.Model(id: "openai/gpt-large", name: "GPT Large"),
            AIModelDiscovery.Model(id: "google/gemini", name: "Gemini")
        ]
        expect(
            AIModelDiscovery.search(models, query: "").isEmpty,
            "an empty search never renders the complete provider catalog")
        expect(
            AIModelDiscovery.search(models, query: "openai").map(\.id)
                == ["openai/gpt-small", "openai/gpt-large"],
            "a provider name finds its models in provider order")
        expect(
            AIModelDiscovery.search(models, query: "GPT Large").first?.id
                == "openai/gpt-large",
            "an exact display-name match ranks first")
        expect(
            AIModelDiscovery.search(
                models, query: "gpt", excluding: ["openai/gpt-small"], limit: 1
            ).map(\.id) == ["openai/gpt-large"],
            "search excludes selected models and caps visible results")
    }

    static func endpointPolicyRejectsUnsafeRemoteURLs() {
        expect(
            (try? AIEndpointPolicy.validate("https://example.com/v1")) != nil,
            "remote HTTPS endpoints are accepted")
        expect(
            (try? AIEndpointPolicy.validate("http://localhost:11434/v1")) != nil,
            "local HTTP endpoints are accepted")
        expect(
            (try? AIEndpointPolicy.validate("http://127.0.0.1:1234/v1")) != nil,
            "IPv4 loopback endpoints are accepted")
        expect(
            (try? AIEndpointPolicy.validate("http://example.com/v1")) == nil,
            "remote plaintext endpoints are rejected")
        expect(
            (try? AIEndpointPolicy.validate("not a url")) == nil,
            "malformed endpoints are rejected")
        expect(
            (try? AIEndpointPolicy.validate("ftp://localhost/v1")) == nil,
            "a loopback host does not excuse a scheme the transport cannot speak")
        expect(
            (try? AIEndpointPolicy.validate("file:///etc/hosts")) == nil,
            "file URLs are not a provider")
    }

    static func storedKeysDoNotFollowARetargetedConnection() {
        var saved = AIConnection()
        saved.provider = .openAI
        saved.baseURL = "https://api.openai.com/v1"
        expect(
            AIEndpointPolicy.sameDestination(saved, saved),
            "an untouched connection still points where its key was issued")

        var switchedProvider = saved
        switchedProvider.provider = .anthropic
        expect(
            !AIEndpointPolicy.sameDestination(switchedProvider, saved),
            "a new provider is a new destination, so the OpenAI key must not go to Anthropic")

        var switchedURL = saved
        switchedURL.baseURL = "https://gateway.example.com/v1"
        expect(
            !AIEndpointPolicy.sameDestination(switchedURL, saved),
            "a retyped base URL is a new destination, whatever the provider preset still says")

        var renamed = saved
        renamed.name = "Work key"
        renamed.models = ["gpt-5.4-mini"]
        expect(
            AIEndpointPolicy.sameDestination(renamed, saved),
            "editing a label or the model list is not a retarget and keeps the saved key")
    }

    static func savingAConnectionDecidesItsKey() {
        var remote = AIConnection()
        remote.provider = .openAI
        remote.baseURL = "https://api.openai.com/v1"
        var local = remote
        local.baseURL = "http://localhost:11434/v1"
        var moved = remote
        moved.baseURL = "https://gateway.example.com/v1"
        typealias Policy = AIConnectionKeyPolicy

        expect(
            Policy.resolve(enteredKey: "  sk-new \n", connection: remote, saved: nil, hasStoredKey: false)
                == .store("sk-new"),
            "a typed key is stored trimmed")
        expect(
            Policy.resolve(enteredKey: "sk-new", connection: moved, saved: remote, hasStoredKey: true)
                == .store("sk-new"),
            "a retarget that brings its own key replaces the old one")
        expect(
            Policy.resolve(enteredKey: " ", connection: moved, saved: remote, hasStoredKey: true)
                == .reject("Enter an API key for this endpoint — the saved key stays with the old one."),
            "a remote retarget without a key is refused, so the old key never reaches the new host")
        expect(
            Policy.resolve(enteredKey: "", connection: local, saved: remote, hasStoredKey: true)
                == .removeStored,
            "a retarget to loopback drops the key issued for the remote endpoint")
        expect(
            Policy.resolve(enteredKey: "", connection: remote, saved: nil, hasStoredKey: false)
                == .reject("Enter an API key for this remote provider."),
            "a new remote connection needs a key")
        expect(
            Policy.resolve(enteredKey: "", connection: local, saved: nil, hasStoredKey: false) == .keep,
            "a loopback endpoint saves without a key")
        expect(
            Policy.resolve(enteredKey: "", connection: remote, saved: remote, hasStoredKey: true) == .keep,
            "an unchanged endpoint keeps its saved key")
        expect(
            Policy.resolve(enteredKey: "", connection: moved, saved: remote, hasStoredKey: false)
                == .reject("Enter an API key for this remote provider."),
            "with no saved key there is nothing to retarget, only a missing key")
    }

    static func brandsResolveFromModelIDs() {
        let expected: [(String, AIBrand?)] = [
            ("openai/gpt-oss-20b", .openAI), ("o4-mini", .openAI), ("o3", .openAI),
            ("anthropic/claude-sonnet-4", .claude), ("google/gemma-3-27b-it", .gemini),
            ("x-ai/grok-4", .x), ("deepseek/deepseek-r1", .deepSeek), ("qwen/qwq-32b", .qwen),
            ("mistralai/codestral-2501", .mistral), ("meta-llama/llama-3.3-70b", .meta),
            ("moonshotai/kimi-k2", .kimi), ("minimax/minimax-m1", .miniMax),
            ("perplexity/sonar-pro", .perplexity), ("z-ai/glm-4.5", .zai),
            ("openrouter/auto", .openRouter), ("cohere/command-r", nil), ("o10", nil)
        ]
        for (model, brand) in expected {
            expect(
                AIBrand.resolve(model: model) == brand, "\(model) resolves to \(String(describing: brand))")
        }
        expect(
            AIBrand.resolve(provider: .anthropic, model: "whatever") == .claude,
            "a vendor endpoint names its brand regardless of the model id")
        expect(
            AIBrand.resolve(provider: .openAICompatible, model: "deepseek-chat") == .deepSeek,
            "a compatible endpoint resolves the brand from the model id")
    }

    static func conversationSettingsPersistAndDecide() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func decide(
            _ opensTo: AIOpensTo, _ after: AINewChatAfter, idle: TimeInterval?
        )
            -> AIConversationOpenPolicy.Decision
        {
            AIConversationOpenPolicy.decide(
                opensTo: opensTo, newAfter: after,
                lastActiveAt: idle.map { now.addingTimeInterval(-$0) }, now: now)
        }

        expect(
            decide(.newConversation, .never, idle: 0) == .startNew,
            "A New Conversation always starts fresh")
        expect(
            decide(.recent, .never, idle: 400 * 86_400) == .resume,
            "Never means no amount of idling starts a new chat")
        expect(decide(.recent, .fiveMinutes, idle: nil) == .startNew, "nothing to resume is new")
        expect(
            decide(.recent, .fiveMinutes, idle: 299) == .resume,
            "inside the window the conversation resumes")
        expect(
            decide(.recent, .fiveMinutes, idle: 301) == .startNew,
            "past the window the next summon starts fresh")
        expect(
            decide(.recent, .fiveMinutes, idle: 300) == .startNew,
            "the boundary itself starts fresh, so the window is exclusive at its end")
        // A backwards clock yields a negative interval; it must not strand a reader in a chat.
        expect(
            decide(.recent, .twoMinutes, idle: -3_600) == .resume,
            "a clock that moved backwards resumes rather than misreading the idle time")

        expect(
            AIRetention.allCases.allSatisfy { !$0.title.isEmpty },
            "every retention names itself")
        expect(
            AIRetention.week.cutoff(from: now) == now.addingTimeInterval(-7 * 86_400),
            "a week's cutoff is seven days back")
        expect(
            AINewChatAfter.allCases.filter { $0.rawValue == 0 }.isEmpty,
            "no timeout uses 0, which an unset key would swallow before the default applied")

        let suite = "AIProviderTests.conversations"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }

        let fresh = AISettingsStore(defaults: defaults)
        expect(fresh.retention == .forever, "retention defaults to Forever, so upgrading deletes nothing")
        expect(fresh.opensTo == .recent, "chat reopens on the recent conversation by default")
        expect(fresh.newChatAfter == .fiveMinutes, "the idle window defaults to five minutes")
        expect(fresh.toolRounds == .twentyFive, "a reply's tool rounds default to 25")

        fresh.retention = .week
        fresh.opensTo = .newConversation
        fresh.newChatAfter = .never
        fresh.toolRounds = .fifty
        let reopened = AISettingsStore(defaults: defaults)
        expect(reopened.toolRounds == .fifty, "the tool round cap persists")
        reopened.toolRounds = .unlimited
        expect(
            AISettingsStore(defaults: defaults).toolRounds == .unlimited,
            "Unlimited persists rather than reading as the default")
        expect(AIToolRounds.unlimited.limit == nil, "and hands the loop no cap")
        expect(AIToolRounds.fifty.limit == 50, "while a step hands it its own number")
        defaults.set(7, forKey: AppSettingsKey.aiToolRounds.rawValue)
        expect(
            AISettingsStore(defaults: defaults).toolRounds == .twentyFive,
            "a stored cap no case carries reads as the default rather than an arbitrary number")
        defaults.set(0, forKey: AppSettingsKey.aiToolRounds.rawValue)
        expect(
            AISettingsStore(defaults: defaults).toolRounds == .twentyFive,
            "and so does a 0, which is neither a step nor Unlimited")
        expect(reopened.retention == .week, "retention persists")
        expect(reopened.opensTo == .newConversation, "the open policy persists")
        expect(reopened.newChatAfter == .never, "Never persists rather than reading as the default")
    }

    static func onDeviceSelectionsRoundTripAndLead() {
        let encoded = try? JSONEncoder().encode(AIModelSelection.appleIntelligence)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(AIModelSelection.self, from: $0) }
        expect(decoded == .appleIntelligence, "the on-device selection survives a round trip")
        expect(
            AIModelSelection.appleIntelligence.model == AppleIntelligence.modelID,
            "the on-device selection reports a stable model id")
        expect(
            AIModelSelection.appleIntelligence.source == .appleIntelligence,
            "the on-device selection is its own source")
        expect(
            AIModelSelection.appleIntelligence.isOnDevice
                && !AIModelSelection.codex(model: "gpt-5", effort: nil).isOnDevice,
            "only the on-device selection reads as on device")

        let legacy = Data(#"{"chatGPT":{"model":"gpt-5","effort":"high"}}"#.utf8)
        expect(
            (try? JSONDecoder().decode(AIModelSelection.self, from: legacy))
                == .codex(model: "gpt-5", effort: "high"),
            "the old ChatGPT selection migrates to the installed Codex route")

        let suite = "AIProviderTests.onDevice"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }

        let store = AISettingsStore(defaults: defaults, isAppleIntelligenceAvailable: { true })
        expect(
            store.defaultModel == .appleIntelligence,
            "the on-device route is the default on an unconfigured Mac")

        // A configured connection must not be displaced by resolution running a second time.
        let connectionID = UUID()
        store.save(AIConnection(id: connectionID, name: "Local", models: ["m"]))
        store.select(.api(connection: connectionID, model: "m", effort: nil))
        store.resolveDefaultModel()
        expect(
            store.defaultModel == .api(connection: connectionID, model: "m", effort: nil),
            "resolution never overrides a selection the reader made")

        // A removed connection falls forward to the route that is always configured.
        store.removeConnection(id: connectionID)
        expect(
            store.defaultModel == .appleIntelligence,
            "a removed connection falls forward to the on-device route")

        let without = AISettingsStore(defaults: defaults, isAppleIntelligenceAvailable: { false })
        without.resolveDefaultModel()
        expect(
            without.defaultModel == .appleIntelligence,
            "an unavailable model does not silently reroute a stored on-device selection")
    }

    static func settingsPersistAndRepairSelections() {
        let suite = "AIProviderTests.persistence"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let firstID = UUID()
        let secondID = UUID()

        var first = AIConnection(
            id: firstID, name: "  Work  ", provider: .openRouter,
            models: [" model-a ", "model-a", "model-b"],
            reasoningOptions: [
                "model-b": .init(efforts: ["medium", "low"], defaultEffort: "medium")
            ])
        first.baseURL = " https://openrouter.ai/api/v1 "
        let store = AISettingsStore(defaults: defaults)
        store.save(first)
        store.save(
            AIConnection(id: secondID, provider: .gemini, models: ["gemini-model"]))
        expect(store.connections.first?.name == "Work", "connection names are normalized")
        expect(
            store.connections.first?.models == ["model-a", "model-b"],
            "models are trimmed and deduplicated")
        expect(
            store.defaultModel == .api(connection: firstID, model: "model-a", effort: nil),
            "the first saved model becomes the default")
        store.select(.api(connection: firstID, model: "model-b", effort: "low"))

        let reopened = AISettingsStore(defaults: defaults)
        expect(reopened.connections == store.connections, "connection metadata survives a restart")
        expect(reopened.defaultModel == store.defaultModel, "the default model survives a restart")
        reopened.removeConnection(id: firstID)
        expect(
            reopened.defaultModel
                == .api(
                    connection: secondID, model: "gemini-model", effort: nil),
            "removing the default connection falls forward to another API model")
    }

    static func installedModelLoadingPreferencePersists() {
        let suite = "AIProviderTests.installedModelLoading"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let store = AISettingsStore(defaults: defaults)
        expect(
            store.enabledInstalledProviders.isEmpty,
            "installed providers are disabled by default")
        store.setInstalledProviderEnabled(true, for: .claude)
        store.setInstalledProviderEnabled(false, for: .openCode)
        let reopened = AISettingsStore(defaults: defaults)
        expect(
            reopened.enabledInstalledProviders == [.claude],
            "an enabled provider survives a restart")
        expect(
            !reopened.enabledInstalledProviders.contains(.openCode),
            "a provider toggle survives a restart")
    }

    static func installedOverridesPersistAndResolve() {
        let suite = "AIProviderTests.installedOverrides"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let kept = KeptVariables()
        let environmentStore = InstalledAIEnvironmentStore(
            values: { kept.values[$0] ?? [:] }, save: { kept.values[$1] = $0 })
        let store = AISettingsStore(defaults: defaults, environmentStore: environmentStore)
        expect(store.launch(for: .codex) == InstalledAILaunch(), "a tool left alone has no override")
        store.setCommandPath("  ~/bin/codex \n", for: .codex)
        expect(store.override(for: .codex).commandPath == "~/bin/codex", "a path is kept trimmed")
        expect(store.launchRevisions[.codex] == 1, "and setting it counts as a change to the launch")
        store.setCommandPath("~/bin/codex", for: .codex)
        expect(store.launchRevisions[.codex] == 1, "the same path again is no change")
        try? store.setEnvironment(
            [
                InstalledAIVariable(name: "HTTPS_PROXY", value: "http://127.0.0.1:9"),
                InstalledAIVariable(name: "HTTPS_PROXY", value: "a second one"),
                InstalledAIVariable(name: "not a name", value: "x"),
                InstalledAIVariable(name: "CODEX_HOME", value: "/tmp/home")
            ], for: .codex)
        expect(
            store.override(for: .codex).environmentNames == ["HTTPS_PROXY", "CODEX_HOME"],
            "variables keep their order, without a repeated or an unusable name")
        expect(
            defaults.data(forKey: AppSettingsKey.aiInstalledOverrides.rawValue)
                .map { String(decoding: $0, as: UTF8.self) }?.contains("127.0.0.1") == false,
            "and no value is written to settings")
        let reopened = AISettingsStore(defaults: defaults, environmentStore: environmentStore)
        expect(
            reopened.launch(for: .codex)
                == InstalledAILaunch(
                    commandPath: "~/bin/codex",
                    environment: ["HTTPS_PROXY": "http://127.0.0.1:9", "CODEX_HOME": "/tmp/home"]),
            "a launch after a restart has the path and the values")
        expect(
            (try? reopened.environment(for: .codex))?.map(\.name) == ["HTTPS_PROXY", "CODEX_HOME"],
            "and the editor lists them in the order they were entered")
        reopened.setCommandPath("", for: .codex)
        try? reopened.setEnvironment([], for: .codex)
        expect(
            defaults.object(forKey: AppSettingsKey.aiInstalledOverrides.rawValue) == nil
                && kept.values[.codex]?.isEmpty == true,
            "clearing both leaves nothing stored")

        let home = NSHomeDirectory()
        let present: (String) -> Bool = { $0 == home + "/bin/codex" }
        expect(InstalledAILaunch().command(isExecutable: present) == .automatic, "no path looks up")
        expect(
            InstalledAILaunch(commandPath: "~/bin/codex").command(isExecutable: present)
                == .executable(URL(fileURLWithPath: home + "/bin/codex")),
            "a path under the home folder may be written with a tilde")
        expect(
            InstalledAILaunch(commandPath: "/opt/none/codex").command(isExecutable: present)
                == .missing(path: "/opt/none/codex"),
            "a path with nothing to run is reported, never replaced by a lookup")
        expect(
            InstalledAILaunch(commandPath: "codex").command(isExecutable: { _ in true })
                == .missing(path: "codex"),
            "a bare name is not a path")
    }

    static func aFailedKeychainReadIsNeverSavedOver() {
        let suite = "AIProviderTests.failedKeychainRead"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let kept = KeptVariables()
        kept.values[.claude] = ["HTTPS_PROXY": "http://127.0.0.1:9"]
        let working = InstalledAIEnvironmentStore(
            values: { kept.values[$0] ?? [:] }, save: { kept.values[$1] = $0 })
        try? AISettingsStore(defaults: defaults, environmentStore: working).setEnvironment(
            [InstalledAIVariable(name: "HTTPS_PROXY", value: "http://127.0.0.1:9")], for: .claude)
        let locked = InstalledAIEnvironmentStore(
            values: { _ in throw KeychainUnreadable() }, save: { kept.values[$1] = $0 })
        let store = AISettingsStore(defaults: defaults, environmentStore: locked)
        expect(
            (try? store.environment(for: .claude)) == nil,
            "a read that fails is an error, never a list of names without values")
        expect(
            (try? store.setEnvironment(
                [InstalledAIVariable(name: "HTTPS_PROXY", value: "")], for: .claude)) == nil,
            "and saving over values that could not be read fails")
        expect(
            kept.values[.claude] == ["HTTPS_PROXY": "http://127.0.0.1:9"],
            "so the stored value survives")
        expect(
            store.launch(for: .claude).environment.isEmpty,
            "a launch that cannot read the values starts without them")
    }

    static func aLaunchInheritsTheReadersVariablesNotTinycastsOwn() {
        let launch = InstalledAILaunch(
            environment: [
                "PATH": "/reader/bin", "HTTPS_PROXY": "proxy", "NO_COLOR": "0",
                "OPENCODE_CONFIG_CONTENT": "{}", "TC_MCP_0_0": "stolen", "1BAD": "x"
            ])
        let inherited = launch.inherited(
            for: .openCode, base: ["PATH": "/usr/bin", "HOME": "/Users/reader", "NO_COLOR": "1"])
        expect(
            inherited["PATH"] == "/reader/bin" && inherited["HTTPS_PROXY"] == "proxy"
                && inherited["HOME"] == "/Users/reader",
            "the reader's variables lie over the app's own")
        expect(
            inherited["OPENCODE_CONFIG_CONTENT"] == nil && inherited["TC_MCP_0_0"] == nil
                && inherited["NO_COLOR"] == "1" && inherited["1BAD"] == nil,
            "but never one Tinycast sets itself, nor one that is not a variable name")
        expect(
            launch.inherited(for: .claude, base: [:])["OPENCODE_CONFIG_CONTENT"] == "{}",
            "a name only another tool reserves is an ordinary variable here")
        expect(
            InstalledAIKind.allCases.allSatisfy { kind in
                kind.managedEnvironment.keys.allSatisfy(kind.isManagedVariable)
            },
            "every variable a tool is launched with is one the reader cannot replace")
    }

    static func switchedOffRoutesLeaveTheDefault() {
        let suite = "AIProviderTests.disabledRoutes"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let store = AISettingsStore(defaults: defaults)
        let first = AIConnection(provider: .openRouter, models: ["first-model"])
        let second = AIConnection(provider: .gemini, models: ["second-model"])
        store.save(first)
        store.save(second)
        expect(store.defaultModel?.source == .api(first.id), "the first connection is the default")
        store.setRoute(.api(first.id), enabled: false)
        expect(
            store.defaultModel?.source == .api(second.id),
            "switching the default's connection off moves the default to one still on")
        let reopened = AISettingsStore(defaults: defaults)
        expect(
            !reopened.isRouteEnabled(.api(first.id)) && reopened.isRouteEnabled(.api(second.id)),
            "a switched-off connection stays off after a restart")
        reopened.setRoute(.appleIntelligence, enabled: false)
        expect(
            !reopened.isRouteEnabled(.appleIntelligence),
            "the on-device model can be switched off like a connection")
        reopened.setRoute(.api(first.id), enabled: true)
        reopened.removeConnection(id: second.id)
        expect(
            reopened.defaultModel?.source == .api(first.id),
            "with the other one gone, the connection switched back on becomes the default")
        reopened.removeConnection(id: first.id)
        expect(
            !reopened.disabledRoutes.contains(AIModelSource.api(first.id).storageKey),
            "removing a connection forgets that it was switched off")
    }

    static func shownModelsFilterThePicker() {
        let suite = "AIProviderTests.shownModels"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let store = AISettingsStore(defaults: defaults)
        let available = ["a", "b", "c"]
        expect(
            available.allSatisfy { store.isModelShown($0, in: .openCode) },
            "a route nobody has trimmed lists every model")
        store.setModel("b", shown: false, in: .openCode, available: available)
        let reopened = AISettingsStore(defaults: defaults)
        expect(
            reopened.isModelShown("a", in: .openCode) && !reopened.isModelShown("b", in: .openCode),
            "an unticked model stays out of the picker after a restart")
        expect(
            !reopened.isModelShown("d", in: .openCode),
            "a trimmed route does not list a model it adds later")
        expect(
            reopened.isModelShown("b", in: .claude),
            "trimming one route leaves the others listing everything")
        reopened.setModel("b", shown: true, in: .openCode, available: available)
        expect(
            reopened.shownModels[AIModelSource.openCode.storageKey] == nil
                && reopened.isModelShown("d", in: .openCode),
            "ticking every model back returns the route to listing all, later ones included")
        reopened.hideAllModels(in: .openCode)
        expect(
            available.allSatisfy { !reopened.isModelShown($0, in: .openCode) },
            "Hide All leaves nothing but the default listed")
        let connection = AIConnection(provider: .openRouter, models: ["x", "y"])
        reopened.save(connection)
        reopened.setModel("y", shown: false, in: .api(connection.id), available: connection.models)
        reopened.removeConnection(id: connection.id)
        expect(
            reopened.shownModels[AIModelSource.api(connection.id).storageKey] == nil,
            "removing a connection forgets which of its models were shown")
    }

    static func subscriptionSelectionsReconcile() {
        let suite = "AIProviderTests.subscription"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let store = AISettingsStore(defaults: defaults)
        let model = ChatGPTSubscription.Model(
            id: "gpt", name: "GPT",
            efforts: [
                .init(id: "low", detail: nil), .init(id: "high", detail: nil)
            ], defaultEffort: "high", isDefault: true)
        store.select(.codex(model: "gpt", effort: "missing"))
        store.reconcile(codexModels: [model], isUnavailable: false)
        expect(
            store.defaultModel == .codex(model: "gpt", effort: "high"),
            "a removed reasoning tier falls back to the model default")
        store.reconcile(codexModels: [], isUnavailable: true)
        expect(store.defaultModel == nil, "signing out clears an unusable Codex default")

        store.select(.claude(model: "removed", effort: nil))
        store.reconcile(
            installed: .claude,
            models: [InstalledAIModel(id: "sonnet", name: "Claude Sonnet")],
            isUnavailable: false)
        expect(
            store.defaultModel == .claude(model: "sonnet", effort: nil),
            "an installed catalog replaces a model alias that disappeared")
        store.reconcile(installed: .claude, models: [], isUnavailable: true)
        expect(store.defaultModel == nil, "signing out clears an unusable Claude default")
    }
}

/// `removePersistentDomain` only empties the domain; cfprefsd still leaves the plist on disk.
private func discardSuite(_ name: String, _ defaults: UserDefaults) {
    defaults.removePersistentDomain(forName: name)
    UserDefaults.standard.removeSuite(named: name)
    CFPreferencesAppSynchronize(name as CFString)
    try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(name).plist"))
}

/// A fixed suite name stops cfprefsd accumulating a plist per run.
private func isolatedDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Stands in for the Keychain: what a harness saved, read back the way a launch would.
private final class KeptVariables: @unchecked Sendable {
    var values: [InstalledAIKind: [String: String]] = [:]
}

private struct KeychainUnreadable: Error {}

import Foundation
import Observation

@MainActor
@Observable
final class AISettingsStore {
    private let defaults: UserDefaults

    private(set) var connections: [AIConnection] {
        didSet { persistConnections() }
    }
    private(set) var defaultModel: AIModelSelection? {
        didSet { persistDefaultModel() }
    }
    /// Off by default: a prompt reaches a search engine only once the user has said so.
    var webSearchEnabled: Bool {
        didSet { defaults.set(webSearchEnabled, forKey: AppSettingsKey.aiWebSearch.rawValue) }
    }
    /// Appended to `AIInstructions.preamble` on every turn, so it is billed on every turn.
    var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: AppSettingsKey.aiSystemPrompt.rawValue) }
    }
    /// On by default: without it a model has no idea what app it is answering for.
    var systemPromptEnabled: Bool {
        didSet {
            defaults.set(systemPromptEnabled, forKey: AppSettingsKey.aiSystemPromptEnabled.rawValue)
        }
    }
    /// Forever by default, so upgrading deletes nothing the reader did not ask to lose.
    var retention: AIRetention {
        didSet { defaults.set(retention.rawValue, forKey: AppSettingsKey.aiRetention.rawValue) }
    }
    var opensTo: AIOpensTo {
        didSet { defaults.set(opensTo.rawValue, forKey: AppSettingsKey.aiOpensTo.rawValue) }
    }
    var newChatAfter: AINewChatAfter {
        didSet {
            defaults.set(newChatAfter.rawValue, forKey: AppSettingsKey.aiNewChatAfter.rawValue)
        }
    }
    var toolRounds: AIToolRounds {
        didSet { defaults.set(toolRounds.rawValue, forKey: AppSettingsKey.aiToolRounds.rawValue) }
    }
    /// Per route, the models its picker lists; no entry lists all it offers, later ones too.
    private(set) var shownModels: [String: [String]] {
        didSet { defaults.set(shownModels, forKey: AppSettingsKey.aiShownModels.rawValue) }
    }
    /// The on-device model and API connections switched off without being removed.
    private(set) var disabledRoutes: Set<String> {
        didSet {
            defaults.set(disabledRoutes.sorted(), forKey: AppSettingsKey.aiDisabledRoutes.rawValue)
        }
    }
    var enabledInstalledProviders: Set<InstalledAIKind> {
        didSet {
            let sorted = enabledInstalledProviders.sorted { $0.rawValue < $1.rawValue }
            guard let data = try? JSONEncoder().encode(sorted) else { return }
            defaults.set(data, forKey: AppSettingsKey.aiInstalledProviders.rawValue)
        }
    }
    /// Per installed tool, a command path and variable names; a tool left alone has no entry.
    private(set) var installedOverrides: [InstalledAIKind: InstalledAIOverride] {
        didSet { persistInstalledOverrides() }
    }
    /// Bumped by every edit to a tool's launch, a changed value included, which no name shows.
    private(set) var launchRevisions: [InstalledAIKind: Int] = [:]

    /// Asked each time: the model lands mid-session, and a flag read at launch would never notice.
    @ObservationIgnored let isAppleIntelligenceAvailable: @Sendable () -> Bool
    @ObservationIgnored private let environmentStore: InstalledAIEnvironmentStore

    init(
        defaults: UserDefaults = .standard,
        environmentStore: InstalledAIEnvironmentStore = .none,
        isAppleIntelligenceAvailable: @escaping @Sendable () -> Bool = { false }
    ) {
        self.defaults = defaults
        self.environmentStore = environmentStore
        self.isAppleIntelligenceAvailable = isAppleIntelligenceAvailable
        func decoded<T: Decodable>(_ key: AppSettingsKey) -> T? {
            defaults.data(forKey: key.rawValue)
                .flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        let overrides: [String: InstalledAIOverride] = decoded(.aiInstalledOverrides) ?? [:]
        installedOverrides = Dictionary(
            uniqueKeysWithValues: overrides.compactMap { key, value in
                InstalledAIKind(rawValue: key).map { ($0, value) }
            })
        connections = decoded(.aiConnections) ?? []
        defaultModel = decoded(.aiDefaultModel)
        webSearchEnabled =
            defaults.object(forKey: AppSettingsKey.aiWebSearch.rawValue) as? Bool ?? false
        systemPrompt = defaults.string(forKey: AppSettingsKey.aiSystemPrompt.rawValue) ?? ""
        systemPromptEnabled =
            defaults.object(forKey: AppSettingsKey.aiSystemPromptEnabled.rawValue) as? Bool ?? true
        // Unset reads as 0, which no retention case carries — `forever` is negative on purpose.
        retention =
            AIRetention(rawValue: defaults.integer(forKey: AppSettingsKey.aiRetention.rawValue))
            ?? .forever
        opensTo =
            AIOpensTo(rawValue: defaults.integer(forKey: AppSettingsKey.aiOpensTo.rawValue))
            ?? .recent
        newChatAfter =
            AINewChatAfter(rawValue: defaults.integer(forKey: AppSettingsKey.aiNewChatAfter.rawValue))
            ?? .fiveMinutes
        toolRounds =
            AIToolRounds(rawValue: defaults.integer(forKey: AppSettingsKey.aiToolRounds.rawValue))
            ?? .twentyFive
        shownModels =
            defaults.dictionary(forKey: AppSettingsKey.aiShownModels.rawValue) as? [String: [String]]
            ?? [:]
        disabledRoutes = Set(defaults.stringArray(forKey: AppSettingsKey.aiDisabledRoutes.rawValue) ?? [])
        enabledInstalledProviders = Set(decoded(.aiInstalledProviders) as [InstalledAIKind]? ?? [])
        if case .api(let connection, let model, _) = defaultModel,
            !connections.contains(where: { $0.id == connection && $0.models.contains(model) })
        {
            defaultModel = firstAvailableSelection()
        }
        if let source = defaultModel?.source, !isRouteEnabled(source), source.installedKind == nil {
            defaultModel = firstAvailableSelection()
        }
        if defaultModel == nil {
            defaultModel = firstAvailableSelection()
        }
    }

    func connection(id: UUID) -> AIConnection? {
        connections.first { $0.id == id }
    }

    func select(_ selection: AIModelSelection) {
        if case .api(let connection, let model, _) = selection {
            guard self.connection(id: connection)?.models.contains(model) == true else { return }
        }
        defaultModel = selection
    }

    func save(_ connection: AIConnection) {
        let connection = normalized(connection)
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        if case .api(connection.id, let model, let effort) = defaultModel {
            defaultModel =
                connection.models.contains(model)
                ? connection.selection(model, effort: effort) : connection.firstSelection
        }
        if defaultModel == nil { defaultModel = connection.firstSelection }
    }

    func removeConnection(id: UUID) {
        connections.removeAll { $0.id == id }
        shownModels[AIModelSource.api(id).storageKey] = nil
        disabledRoutes.remove(AIModelSource.api(id).storageKey)
        guard case .api(id, _, _) = defaultModel else { return }
        defaultModel = firstAvailableSelection()
    }

    func reconcile(codexModels models: [ChatGPTSubscription.Model], isUnavailable: Bool) {
        guard case .codex(let model, let effort) = defaultModel else { return }
        if isUnavailable {
            defaultModel = firstAvailableSelection()
            return
        }
        guard !models.isEmpty else { return }
        if let match = models.first(where: { $0.id == model }) {
            let resolved = match.resolvedEffort(effort)
            if resolved != effort { defaultModel = .codex(model: model, effort: resolved) }
            return
        }
        guard let replacement = models.first(where: \.isDefault) ?? models.first else { return }
        defaultModel = .codex(model: replacement.id, effort: replacement.resolvedEffort(nil))
    }

    func reconcile(installed kind: InstalledAIKind, models: [InstalledAIModel], isUnavailable: Bool) {
        guard kind != .codex, let selected = defaultModel, selected.source == kind.source else { return }
        let selectedModel = selected.model
        if isUnavailable {
            defaultModel = firstAvailableSelection()
            return
        }
        guard !models.isEmpty else { return }
        if let match = models.first(where: { $0.id == selectedModel }) {
            let resolved = match.resolvedEffort(defaultModel?.effort)
            if resolved != defaultModel?.effort { defaultModel = defaultModel?.withEffort(resolved) }
            return
        }
        guard let replacement = models.first else { return }
        defaultModel = .installed(kind, model: replacement.id, effort: replacement.resolvedEffort(nil))
    }

    /// Nothing chosen yet takes the route that needs no account, leaving a real stored selection.
    func resolveDefaultModel() {
        guard defaultModel == nil, let selection = firstAvailableSelection() else { return }
        defaultModel = selection
    }

    func isRouteEnabled(_ source: AIModelSource) -> Bool {
        if let kind = source.installedKind { return enabledInstalledProviders.contains(kind) }
        return !disabledRoutes.contains(source.storageKey)
    }

    /// An installed route keeps its own switch; the others move the default off when switched off.
    func setRoute(_ source: AIModelSource, enabled: Bool) {
        if let kind = source.installedKind {
            setInstalledProviderEnabled(enabled, for: kind)
            return
        }
        if enabled {
            disabledRoutes.remove(source.storageKey)
        } else {
            disabledRoutes.insert(source.storageKey)
            if defaultModel?.source == source { defaultModel = firstAvailableSelection() }
        }
        if defaultModel == nil { defaultModel = firstAvailableSelection() }
    }

    func isModelShown(_ model: String, in source: AIModelSource) -> Bool {
        shownModels[source.storageKey]?.contains(model) ?? true
    }

    /// `available` is the route's whole list, needed the first time one model is hidden from it.
    func setModel(_ model: String, shown: Bool, in source: AIModelSource, available: [String]) {
        var shownList = shownModels[source.storageKey] ?? available
        shownList.removeAll { $0 == model }
        if shown { shownList.append(model) }
        // All shown again drops the entry, so a model the route adds later appears too.
        let everything = Set(available)
        shownModels[source.storageKey] =
            everything.isSubset(of: shownList) ? nil : shownList.filter(everything.contains)
    }

    func showAllModels(in source: AIModelSource) {
        shownModels[source.storageKey] = nil
    }

    /// The default model stays listed, since the picker must be able to show what is selected.
    func hideAllModels(in source: AIModelSource) {
        let kept = defaultModel.flatMap { $0.source == source ? [$0.model] : nil } ?? []
        shownModels[source.storageKey] = kept
    }

    func setInstalledProviderEnabled(_ enabled: Bool, for kind: InstalledAIKind) {
        if enabled {
            enabledInstalledProviders.insert(kind)
        } else {
            enabledInstalledProviders.remove(kind)
        }
    }

    func override(for kind: InstalledAIKind) -> InstalledAIOverride {
        installedOverrides[kind] ?? InstalledAIOverride()
    }

    func setCommandPath(_ path: String, for kind: InstalledAIKind) {
        var override = override(for: kind)
        override.commandPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard override != self.override(for: kind) else { return }
        installedOverrides[kind] = override.isEmpty ? nil : override
        launchRevisions[kind, default: 0] += 1
    }

    func environment(for kind: InstalledAIKind) throws -> [InstalledAIVariable] {
        let values = try environmentStore.values(kind)
        return override(for: kind).environmentNames.map {
            InstalledAIVariable(name: $0, value: values[$0] ?? "")
        }
    }

    /// Values are saved first: names without their values would launch the tool half configured.
    func setEnvironment(_ variables: [InstalledAIVariable], for kind: InstalledAIKind) throws {
        var seen = Set<String>()
        let kept = variables.filter {
            InstalledAILaunch.isVariableName($0.name) && seen.insert($0.name).inserted
        }
        guard try kept != environment(for: kind) else { return }
        try environmentStore.save(Dictionary(uniqueKeysWithValues: kept.map { ($0.name, $0.value) }), kind)
        var override = override(for: kind)
        override.environmentNames = kept.map(\.name)
        installedOverrides[kind] = override.isEmpty ? nil : override
        launchRevisions[kind, default: 0] += 1
    }

    /// Reads the Keychain only for a tool that has variables, so most launches never touch it.
    func launch(for kind: InstalledAIKind) -> InstalledAILaunch {
        let override = override(for: kind)
        guard !override.environmentNames.isEmpty else {
            return InstalledAILaunch(commandPath: override.commandPath)
        }
        let names = Set(override.environmentNames)
        let values = (try? environmentStore.values(kind)) ?? [:]
        return InstalledAILaunch(
            commandPath: override.commandPath,
            environment: values.filter { names.contains($0.key) })
    }

    /// The on-device model leads: free, private, always configured, so never a surprising landing.
    private func firstAvailableSelection() -> AIModelSelection? {
        if isAppleIntelligenceAvailable(), isRouteEnabled(.appleIntelligence) {
            return .appleIntelligence
        }
        return connections.lazy.filter { self.isRouteEnabled(.api($0.id)) }
            .compactMap(\.firstSelection).first
    }

    private func persistConnections() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: AppSettingsKey.aiConnections.rawValue)
    }

    private func persistInstalledOverrides() {
        let keyed = Dictionary(uniqueKeysWithValues: installedOverrides.map { ($0.key.rawValue, $0.value) })
        guard !keyed.isEmpty, let data = try? JSONEncoder().encode(keyed) else {
            defaults.removeObject(forKey: AppSettingsKey.aiInstalledOverrides.rawValue)
            return
        }
        defaults.set(data, forKey: AppSettingsKey.aiInstalledOverrides.rawValue)
    }

    private func persistDefaultModel() {
        guard let defaultModel, let data = try? JSONEncoder().encode(defaultModel) else {
            defaults.removeObject(forKey: AppSettingsKey.aiDefaultModel.rawValue)
            return
        }
        defaults.set(data, forKey: AppSettingsKey.aiDefaultModel.rawValue)
    }

    private func normalized(_ connection: AIConnection) -> AIConnection {
        var connection = connection
        connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.baseURL = connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        connection.models = connection.models.compactMap {
            let model = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
        connection.visionModels = connection.visionModels.filter(seen.contains)
        connection.reasoningOptions = connection.reasoningOptions?.filter {
            seen.contains($0.key) && !$0.value.efforts.isEmpty
        }
        if connection.reasoningOptions?.isEmpty == true { connection.reasoningOptions = nil }
        return connection
    }
}

import Foundation

struct AIModelOption: Identifiable {
    let selection: AIModelSelection
    let title: String
    let sourceTitle: String
    let menuIcon: PopoverMenuIcon

    static let appleIntelligenceIcon = PopoverMenuIcon.symbol("apple.intelligence")

    /// Every route the Mac can reach, on-device first: it is the one an unconfigured Mac has.
    @MainActor
    static func availableGroups(
        settings: AISettingsStore, subscription: ChatGPTSubscriptionManager,
        installedAI: InstalledAIManager
    ) -> [AIModelOptionGroup] {
        // The default stays listed even when unticked, or the picker could not show what it holds.
        func shown(_ model: String, _ source: AIModelSource) -> Bool {
            settings.isModelShown(model, in: source)
                || (settings.defaultModel?.source == source && settings.defaultModel?.model == model)
        }
        var options: [AIModelOption] = []
        func add(_ selection: AIModelSelection, _ title: String, _ sourceTitle: String) {
            options.append(
                AIModelOption(
                    selection: selection, title: title, sourceTitle: sourceTitle,
                    menuIcon: icon(of: selection, settings: settings)))
        }
        if settings.isAppleIntelligenceAvailable(), settings.isRouteEnabled(.appleIntelligence) {
            add(.appleIntelligence, AppleIntelligence.title, "On device")
        }
        for kind in InstalledAIKind.allCases where settings.enabledInstalledProviders.contains(kind) {
            for model in models(of: kind, subscription: subscription, installedAI: installedAI)
            where shown(model.id, kind.source) {
                add(.installed(kind, model: model.id, effort: nil), model.name, kind.title)
            }
        }
        for connection in settings.connections where settings.isRouteEnabled(.api(connection.id)) {
            for model in connection.models where shown(model, .api(connection.id)) {
                add(.api(connection: connection.id, model: model, effort: nil), model, connection.title)
            }
        }
        var groups: [AIModelOptionGroup] = []
        for option in options {
            if groups.last?.id == option.selection.source {
                groups[groups.count - 1].options.append(option)
            } else {
                groups.append(
                    AIModelOptionGroup(
                        source: option.selection.source, title: option.sourceTitle,
                        options: [option]))
            }
        }
        return groups
    }

    /// A route's catalogue while it is usable: Codex's from its app-server, the rest from a probe.
    @MainActor
    static func models(
        of kind: InstalledAIKind, subscription: ChatGPTSubscriptionManager,
        installedAI: InstalledAIManager
    ) -> [InstalledAIModel] {
        guard kind != .codex else {
            guard subscription.isConnected else { return [] }
            return subscription.models.map { InstalledAIModel(id: $0.id, name: $0.name) }
        }
        let status = installedAI.status(for: kind)
        return status.isReady ? status.models : []
    }

    /// An unrecognised model keeps the generic sparkle rather than borrowing someone's mark.
    static func icon(_ brand: AIBrand?) -> PopoverMenuIcon {
        brand.map { .asset($0.assetName) } ?? .symbol("sparkles")
    }

    static func icon(for kind: InstalledAIKind) -> PopoverMenuIcon {
        switch kind {
        case .codex: return icon(.openAI)
        case .claude: return icon(.claude)
        case .grok: return icon(.grok)
        case .openCode: return icon(.openCode)
        case .cursor: return icon(.cursor)
        }
    }

    /// From the selection, not the loaded list: the list arrives after the picker first paints.
    @MainActor
    static func icon(of selected: AIModelSelection?, settings: AISettingsStore) -> PopoverMenuIcon {
        switch selected {
        case .appleIntelligence?: return appleIntelligenceIcon
        case .openCode(let model, _)?: return icon(AIBrand.resolve(model: model))
        case .api(let connection, let model, _)?:
            return icon(
                settings.connection(id: connection).flatMap {
                    AIBrand.resolve(provider: $0.provider, model: model)
                })
        case let selected?: return selected.source.installedKind.map(icon(for:)) ?? icon(nil)
        case nil: return icon(nil)
        }
    }

    /// The model list only names a route; the effort it comes with is that route's default.
    @MainActor
    static func withDefaultEffort(
        _ selection: AIModelSelection, settings: AISettingsStore,
        subscription: ChatGPTSubscriptionManager, installedAI: InstalledAIManager
    ) -> AIModelSelection {
        let model = selection.model
        let effort: String?
        switch selection.source {
        case .appleIntelligence:
            return selection
        case .codex:
            effort = subscription.models.first { $0.id == model }?.resolvedEffort(nil)
        case .claude, .grok, .openCode, .cursor:
            effort = installedAI.models(for: selection.source)
                .first { $0.id == model }?.resolvedEffort(nil)
        case .api(let connection):
            effort = settings.connection(id: connection)?
                .reasoningOptions(for: model)?.resolvedEffort(nil)
        }
        return selection.withEffort(effort)
    }

    @MainActor
    static func efforts(
        for selection: AIModelSelection?, settings: AISettingsStore,
        subscription: ChatGPTSubscriptionManager, installedAI: InstalledAIManager
    ) -> [ChatGPTSubscription.Effort] {
        guard let selection else { return [] }
        let model = selection.model
        switch selection.source {
        case .appleIntelligence:
            return []
        case .codex:
            return subscription.models.first { $0.id == model }?.efforts ?? []
        case .claude, .grok, .openCode, .cursor:
            return installedAI.models(for: selection.source).first { $0.id == model }?.efforts ?? []
        case .api(let connection):
            return settings.connection(id: connection)?.reasoningOptions(for: model)?
                .efforts.map { ChatGPTSubscription.Effort(id: $0, detail: nil) } ?? []
        }
    }

    var id: AIModelSelection { selection }
    func matches(_ other: AIModelSelection) -> Bool {
        selection.source == other.source && selection.model == other.model
    }
}

struct AIModelOptionGroup: Identifiable {
    let source: AIModelSource
    let title: String
    var options: [AIModelOption]
    var id: AIModelSource { source }
}

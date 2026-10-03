import SwiftUI

struct AIModelSelectionRows<ModelLabel: View, EffortLabel: View>: View {
    @Environment(AISettingsStore.self) private var settings
    @Environment(ChatGPTSubscriptionManager.self) private var subscription
    @Environment(InstalledAIManager.self) private var installedAI

    let selection: AIModelSelection?
    /// Offers `nil` as a choice of its own, for a caller whose empty selection means another route.
    var inheritedTitle: String?
    let select: (AIModelSelection?) -> Void
    @ViewBuilder let modelLabel: () -> ModelLabel
    @ViewBuilder let effortLabel: () -> EffortLabel

    var body: some View {
        let groups = AIModelOption.availableGroups(
            settings: settings, subscription: subscription, installedAI: installedAI)
        let efforts = AIModelOption.efforts(
            for: selection, settings: settings, subscription: subscription, installedAI: installedAI)
        if groups.isEmpty {
            Label("No AI provider configured", systemImage: "sparkles")
                .foregroundStyle(.secondary)
        } else {
            Picker(selection: modelBinding) {
                if let inheritedTitle {
                    Text(inheritedTitle).tag(AIModelSelection?.none)
                    Divider()
                }
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.options) { Text($0.title).tag(Optional($0.selection)) }
                    }
                }
            } label: {
                modelLabel()
            }
            if !efforts.isEmpty {
                Picker(selection: effortBinding) {
                    ForEach(efforts) { Text($0.title).tag($0.id) }
                } label: {
                    effortLabel()
                }
            }
        }
    }

    private var modelBinding: Binding<AIModelSelection?> {
        Binding(
            get: { selection?.withEffort(nil) },
            set: { value in
                select(
                    value.map {
                        AIModelOption.withDefaultEffort(
                            $0, settings: settings, subscription: subscription, installedAI: installedAI)
                    })
            })
    }

    private var effortBinding: Binding<String> {
        Binding(
            get: { selection?.effort ?? "" },
            set: { effort in
                guard let selection else { return }
                select(selection.withEffort(effort))
            })
    }
}

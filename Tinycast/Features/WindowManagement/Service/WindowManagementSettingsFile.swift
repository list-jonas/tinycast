import Foundation

/// Window management's shortcuts and lists in settings.json, each shortcut kept with its record.
@MainActor
struct WindowManagementSettingsFile {
    let sizes: CustomWindowSizeStore
    let layouts: WindowLayoutStore
    let rooms: RoomStore
    let hotKeys: HotKeyManager

    /// Built per read, because the keyboard layout and the Hyper chord both change at run time.
    private var spelling: HotKeySpelling {
        HotKeySpelling(
            characters: ASCIIKeyboardLayout.baseCharacters(for: 0..<128),
            hyperModifiers: KeyShortcut.displayedHyperChord().map(KeyShortcut.carbonModifiers(from:)))
    }

    func commandShortcutsBinding(for key: SettingsFileKey) -> SettingsFileBinding {
        SettingsFileBinding(
            key,
            read: {
                let spelling = self.spelling
                var texts: [WindowCommand.ID: String] = [:]
                for id in WindowCommand.ID.allCases {
                    texts[id] = hotKeys.binding(for: .windowCommand(id: id)).map(spelling.text(for:))
                }
                return WindowManagementFileFormat.json(commandShortcuts: texts)
            },
            write: { json in
                guard let decoded = WindowManagementFileFormat.commandShortcuts(from: json) else {
                    return [.invalidValue(key)]
                }
                let wanted = WindowCommand.ID.allCases.map { id in
                    Wanted(action: .windowCommand(id: id), text: decoded.shortcuts[id], label: "“\(id.rawValue)”")
                }
                return decoded.problems.map { .invalidEntry(key, $0) } + apply(wanted, key: key)
            })
    }

    func customSizesBinding(for key: SettingsFileKey) -> SettingsFileBinding {
        libraryBinding(
            for: key, kind: "custom size", rule: "a name is empty or used twice", records: { sizes.sizes },
            json: WindowManagementFileFormat.json(_:shortcut:), decode: WindowManagementFileFormat.customSizes,
            replace: { sizes.replace(with: $0) }, bound: \.boundCustomWindowSizeIDs,
            action: HotKeyAction.customWindowSize)
    }

    func layoutsBinding(for key: SettingsFileKey) -> SettingsFileBinding {
        libraryBinding(
            for: key, kind: "layout", rule: "a name is empty or used twice, or it has no apps",
            records: { layouts.layouts }, json: WindowManagementFileFormat.json(_:shortcut:),
            decode: WindowManagementFileFormat.layouts, replace: { layouts.replace(with: $0) },
            bound: \.boundWindowLayoutIDs, action: HotKeyAction.windowLayout)
    }

    func roomsBinding(for key: SettingsFileKey) -> SettingsFileBinding {
        libraryBinding(
            for: key, kind: "room", rule: "a name is empty or used twice, or it has no windows",
            records: { rooms.rooms }, json: WindowManagementFileFormat.json(_:shortcut:),
            decode: WindowManagementFileFormat.rooms,
            replace: { incoming in
                let learned = Dictionary(rooms.rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                return rooms.replace(with: incoming.map { room in learned[room.id].map(room.keepingRuntime) ?? room })
            },
            bound: \.boundWindowRoomIDs, action: HotKeyAction.windowRoom)
    }

    /// A list whose records each carry their shortcut; a record the file drops takes its shortcut too.
    private func libraryBinding<Record: WindowLibraryRecord>(
        for key: SettingsFileKey, kind: String, rule: String, records: @escaping () -> [Record],
        json: @escaping (Record, String?) -> SettingsFileJSON,
        decode: @escaping (SettingsFileJSON) -> WindowManagementFileFormat.Decoded<Record>?,
        replace: @escaping ([Record]) -> Int, bound: KeyPath<HotKeyManager, [UUID]>,
        action: @escaping (UUID) -> HotKeyAction
    ) -> SettingsFileBinding {
        SettingsFileBinding(
            key,
            read: {
                let spelling = self.spelling
                return .array(
                    records().map { json($0, hotKeys.binding(for: action($0.id)).map(spelling.text(for:))) })
            },
            write: { file in
                guard let decoded = decode(file) else { return [.invalidValue(key)] }
                let skipped = decoded.records.count - replace(decoded.records)
                var issues = decoded.problems.map { SettingsFileIssue.invalidEntry(key, $0) }
                if skipped > 0 {
                    let noun = skipped == 1 ? "1 \(kind) was" : "\(skipped) \(kind)s were"
                    issues.append(.invalidEntry(key, "\(noun) skipped: \(rule)"))
                }
                let live = records()
                let ids = Set(live.map(\.id))
                for id in hotKeys[keyPath: bound] where !ids.contains(id) {
                    hotKeys.setBinding(nil, for: action(id))
                }
                let wanted = live.map { record in
                    Wanted(
                        action: action(record.id), text: decoded.shortcuts[record.id],
                        label: "\(kind) “\(record.name)”")
                }
                return issues + apply(wanted, key: key)
            })
    }

    // MARK: - Shortcuts

    private struct Wanted {
        let action: HotKeyAction
        let text: String?
        let label: String
    }

    private struct Change {
        let wanted: Wanted
        let binding: HotKeyBinding
        let previous: HotKeyBinding?
        let text: String
    }

    /// Clears every changed binding first, so two shortcuts the file swaps never block each other.
    private func apply(_ wanted: [Wanted], key: SettingsFileKey) -> [SettingsFileIssue] {
        let spelling = self.spelling
        var issues: [SettingsFileIssue] = []
        var changes: [Change] = []
        for item in wanted {
            let current = hotKeys.binding(for: item.action)
            guard let text = item.text else {
                if current != nil { hotKeys.setBinding(nil, for: item.action) }
                continue
            }
            guard let binding = spelling.binding(from: text) else {
                issues.append(.invalidEntry(key, "\(item.label): “\(text)” isn't a shortcut Tinycast can bind"))
                continue
            }
            guard binding != current else { continue }
            if current != nil { hotKeys.setBinding(nil, for: item.action) }
            changes.append(Change(wanted: item, binding: binding, previous: current, text: text))
        }
        for change in changes {
            let action = change.wanted.action
            guard let owner = hotKeys.conflictOwner(of: change.binding, excluding: action) else {
                hotKeys.setBinding(change.binding, for: action)
                continue
            }
            issues.append(.invalidEntry(key, "\(change.wanted.label): “\(change.text)” already runs \(owner)"))
            // The old binding returns when it is still free, so a clash never costs a working one.
            if let previous = change.previous, hotKeys.conflictOwner(of: previous, excluding: action) == nil {
                hotKeys.setBinding(previous, for: action)
            }
        }
        return issues
    }
}

import Foundation

struct SystemAction: Identifiable, Hashable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case lockScreen = "lock-screen"
        case sleep
        case sleepDisplays = "sleep-displays"
        case restart
        case shutDown = "shut-down"
        case logOut = "log-out"
        case showScreenSaver = "show-screen-saver"
        case playPause = "play-pause"
        case nextTrack = "next-track"
        case previousTrack = "previous-track"
        case toggleMute = "toggle-mute"
        case volumeUp = "volume-up"
        case volumeDown = "volume-down"
        case setVolume = "set-volume"
        case volume0 = "volume-0"
        case volume25 = "volume-25"
        case volume50 = "volume-50"
        case volume75 = "volume-75"
        case volume100 = "volume-100"
        case showDesktop = "show-desktop"
        case toggleAppearance = "toggle-system-appearance"
        case toggleStageManager = "toggle-stage-manager"
        case openTrash = "open-trash"
        case emptyTrash = "empty-trash"
        case ejectAllDisks = "eject-all-disks"
        case toggleHiddenFiles = "toggle-hidden-files"
        case hideOtherApps = "hide-all-apps-except-frontmost"
        case unhideAllApps = "unhide-all-hidden-apps"
        case quitAllApps = "quit-all-apps"
        case dismissNotifications = "dismiss-notifications"
        case toggleBluetooth = "toggle-bluetooth"
    }

    /// Whether it confirms first, and the copy; every such action is destructive.
    enum Confirmation: Hashable, Sendable {
        case none
        case required(title: String, message: String)
        /// Asks only while Finder's own "Show warning before emptying the Trash" is on.
        case followsFinder(title: String, message: String)
        /// Quit All alone counts its targets before asking, so its copy is built at call time.
        case computed
    }

    let id: ID
    let name: String
    let sfSymbol: String
    let confirmation: Confirmation

    /// Stable identity for the entry, and with it every persisted key it owns.
    var entryID: String { "system-action:" + id.rawValue }
}

enum SystemActionCatalog {
    static let all: [SystemAction] = SystemAction.ID.allCases.map { id in
        let (name, symbol) = presentation(for: id)
        return SystemAction(id: id, name: name, sfSymbol: symbol, confirmation: confirmation(for: id))
    }

    private static let byEntryID = Dictionary(uniqueKeysWithValues: all.map { ($0.entryID, $0) })
    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func action(forEntryID entryID: String) -> SystemAction? {
        byEntryID[entryID]
    }

    static func action(id: SystemAction.ID) -> SystemAction {
        // Every ID is in `all` by construction, so a miss is a programmer error.
        byID[id]!
    }

    private static func presentation(for id: SystemAction.ID) -> (name: String, symbol: String) {
        switch id {
        case .lockScreen: ("Lock Screen", "lock")
        case .sleep: ("Sleep", "moon.zzz")
        case .sleepDisplays: ("Sleep Displays", "display")
        case .restart: ("Restart", "arrow.clockwise")
        case .shutDown: ("Shut Down", "power")
        case .logOut: ("Log Out", "rectangle.portrait.and.arrow.right")
        case .showScreenSaver: ("Show Screen Saver", "rectangle.inset.filled")
        case .playPause: ("Play / Pause", "playpause")
        case .nextTrack: ("Next Track", "forward.end")
        case .previousTrack: ("Previous Track", "backward.end")
        case .toggleMute: ("Toggle Mute", "speaker.slash")
        case .volumeUp: ("Turn Volume Up", "speaker.plus")
        case .volumeDown: ("Turn Volume Down", "speaker.minus")
        case .setVolume: ("Set Volume…", "speaker.wave.2")
        case .volume0: ("Set Volume to 0%", "speaker.wave.2")
        case .volume25: ("Set Volume to 25%", "speaker.wave.2")
        case .volume50: ("Set Volume to 50%", "speaker.wave.2")
        case .volume75: ("Set Volume to 75%", "speaker.wave.2")
        case .volume100: ("Set Volume to 100%", "speaker.wave.2")
        case .showDesktop: ("Show Desktop", "macwindow.on.rectangle")
        case .toggleAppearance: ("Toggle System Appearance", "circle.lefthalf.filled")
        case .toggleStageManager: ("Toggle Stage Manager", "squares.leading.rectangle")
        case .openTrash: ("Open Trash", "trash")
        case .emptyTrash: ("Empty Trash", "trash.slash")
        case .ejectAllDisks: ("Eject All Disks", "eject")
        case .toggleHiddenFiles: ("Toggle Hidden Files", "eye.slash")
        case .hideOtherApps: ("Hide All Apps Except Frontmost", "eye.slash.circle")
        case .unhideAllApps: ("Unhide All Hidden Apps", "eye.circle")
        case .quitAllApps: ("Quit All Applications", "xmark.circle")
        case .dismissNotifications: ("Dismiss Notifications", "bell.slash")
        // Not an SF Symbol: the logo is a trademark, so this is a bundled asset.
        case .toggleBluetooth: ("Toggle Bluetooth", "bluetooth")
        }
    }

    private static let sessionEndingMessage =
        "Applications with unsaved changes may ask you to save."

    private static func confirmation(for id: SystemAction.ID) -> SystemAction.Confirmation {
        switch id {
        case .restart:
            return .required(title: "Restart your Mac?", message: sessionEndingMessage)
        case .shutDown:
            return .required(title: "Shut down your Mac?", message: sessionEndingMessage)
        case .logOut:
            return .required(title: "Log out now?", message: sessionEndingMessage)
        case .emptyTrash:
            return .followsFinder(
                title: "Empty Trash?",
                message: "The items in the Trash will be permanently deleted.")
        case .quitAllApps:
            return .computed
        default:
            return .none
        }
    }
}

import AppKit
@preconcurrency import ApplicationServices

/// Reads every switchable window over AX, once; apps and windows only, so it stays synchronous.
@MainActor
enum WindowSwitchSweep {
    /// A sweep walks every app, so one hung process must not cost the full messaging timeout.
    private static let sweepTimeout: Float = 0.2

    /// Live AX handles for one window. Never `Sendable`: these do not leave the main actor.
    struct Element {
        let app: NSRunningApplication
        let application: AXUIElement
        let window: AXUIElement
    }

    struct Snapshot {
        var entries: [WindowSwitchEntry]
        var elements: [Int: Element]
    }

    static func snapshot(ranks: [pid_t: Int]) -> Snapshot {
        var entries: [WindowSwitchEntry] = []
        var elements: [Int: Element] = [:]

        for app in WindowInventory.candidates() {
            guard let bundleID = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier
            let application = AXWindowAccess.application(for: pid, timeout: sweepTimeout)
            let iconURL = app.bundleURL
            let iconStamp = iconURL.map(FileIconStamp.value(for:)) ?? 0
            for window in AXWindowAccess.windows(in: application) {
                AXUIElementSetMessagingTimeout(window, sweepTimeout)
                guard isSwitchable(window) else { continue }
                let handle = entries.count
                entries.append(
                    WindowSwitchEntry(
                        handle: handle, appName: app.localizedName ?? bundleID,
                        bundleID: bundleID, iconURL: iconURL, iconStamp: iconStamp,
                        title: AXWindowAccess.string(window, kAXTitleAttribute) ?? "",
                        isMinimized: AXWindowAccess.bool(window, kAXMinimizedAttribute) == true,
                        appRank: ranks[pid] ?? .max))
                elements[handle] = Element(app: app, application: application, window: window)
            }
        }
        return Snapshot(entries: entries, elements: elements)
    }

    /// Looser than the inventory: minimized and other-Space windows, which report no frame, count.
    private static func isSwitchable(_ window: AXUIElement) -> Bool {
        AXWindowAccess.string(window, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String)
    }
}

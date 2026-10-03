import AppKit

/// A session `CGEventTap` on the main run loop; `owner` is passed unretained, so must outlive it.
@MainActor
struct EventTap {
    private let port: CFMachPort
    private let source: CFRunLoopSource

    init?(
        place: CGEventTapPlacement, options: CGEventTapOptions, events: [CGEventType],
        callback: CGEventTapCallBack, owner: AnyObject
    ) {
        let mask = events.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: place, options: options, eventsOfInterest: mask,
                callback: callback, userInfo: Unmanaged.passUnretained(owner).toOpaque())
        else { return nil }
        self.port = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    var isEnabled: Bool { CGEvent.tapIsEnabled(tap: port) }

    func setEnabled(_ enabled: Bool) {
        CGEvent.tapEnable(tap: port, enable: enabled)
    }

    func invalidate() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
    }

    /// Fast user switching hands the keyboard to another session; `onChange` gets whether ours is.
    static func observeSession(
        _ onChange: @escaping @MainActor @Sendable (_ active: Bool) -> Void
    ) -> [NotificationToken] {
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            (NSWorkspace.sessionDidResignActiveNotification, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, true)
        ]
        return names.map { name, active in
            NotificationToken(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { onChange(active) }
                }, center: center)
        }
    }
}

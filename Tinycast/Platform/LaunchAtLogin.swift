import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            try enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        } catch {
            NSLog("Tinycast: launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}

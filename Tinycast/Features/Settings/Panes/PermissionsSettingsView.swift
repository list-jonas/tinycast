import AVFoundation
import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(AppCore.self) private var core
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()
    @State private var calendarAccess = Permissions.calendarAccess()
    @State private var microphoneAccess = Permissions.microphoneAccess()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: SettingsRowTitle(.permissionsAccessibility, "Accessibility"),
                    subtitle: "Pastes into the app you were using.", status: accessibilityStatus,
                    buttonTitle: accessibilityTrusted ? "Open…" : "Grant Access…",
                    help: "Opens Privacy & Security › Accessibility.",
                    action: Permissions.openAccessibilitySettings
                ) {
                    PermissionSettingsIcon(
                        path: "/System/Library/ExtensionKit/Extensions/AccessibilitySettingsExtension.appex")
                }
            } header: {
                SettingsSectionHeader(.permissionsAccessibility)
            }

            Section {
                PermissionRow(
                    title: SettingsRowTitle(.permissionsCalendars, "Calendars"),
                    subtitle: "Finds the join link for your next meeting.", status: calendarStatus,
                    buttonTitle: calendarNeedsPrompt ? "Grant Access…" : "Open…",
                    help: calendarNeedsPrompt
                        ? "Turns the calendar on, then asks macOS for access."
                        : "Opens Privacy & Security › Calendars."
                ) {
                    // Settings lists no app TCC never asked about, so asking is the way in.
                    if calendarNeedsPrompt {
                        core.calendarCoordinator.setCalendarEnabled(true)
                    } else {
                        Permissions.openCalendarSettings()
                    }
                } icon: {
                    PermissionSettingsIcon(path: "/System/Applications/Calendar.app")
                }
            } header: {
                SettingsSectionHeader(.permissionsCalendars)
            }

            Section {
                PermissionRow(
                    title: SettingsRowTitle(.permissionsMicrophone, "Microphone"),
                    subtitle: "Records audio only while dictating.", status: microphoneStatus,
                    buttonTitle: microphoneAccess == .notDetermined ? "Grant Access…" : "Open…",
                    help: microphoneAccess == .notDetermined
                        ? "Asks macOS for microphone access." : "Opens Privacy & Security › Microphone."
                ) {
                    if microphoneAccess == .notDetermined {
                        Task {
                            _ = await Permissions.requestMicrophoneAccess()
                            refresh()
                        }
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                } icon: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: SettingsListMetrics.iconSize - Theme.Spacing.xs))
                        .frame(width: SettingsListMetrics.iconSize)
                        .accessibilityHidden(true)
                }
            } header: {
                SettingsSectionHeader(.permissionsMicrophone)
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.permissions)
        // Polled: macOS posts nothing when a privacy grant changes.
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var calendarNeedsPrompt: Bool { calendarAccess == .notDetermined }

    private var accessibilityStatus: PermissionStatus {
        accessibilityTrusted
            ? ("Granted", "checkmark.circle.fill", .green)
            : ("Not granted", "exclamationmark.triangle.fill", .orange)
    }

    private var calendarStatus: PermissionStatus {
        switch calendarAccess {
        case .granted: ("Granted", "checkmark.circle.fill", .green)
        case .notDetermined: ("Not asked yet", "questionmark.circle.fill", .secondary)
        case .denied: ("Not granted", "exclamationmark.triangle.fill", .orange)
        }
    }

    private var microphoneStatus: PermissionStatus {
        switch microphoneAccess {
        case .authorized: ("Granted", "checkmark.circle.fill", .green)
        case .notDetermined: ("Not asked yet", "questionmark.circle.fill", .secondary)
        default: ("Not granted", "exclamationmark.triangle.fill", .orange)
        }
    }

    private func refresh() {
        let trusted = Permissions.isAccessibilityTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        let access = Permissions.calendarAccess()
        if access != calendarAccess { calendarAccess = access }
        let microphone = Permissions.microphoneAccess()
        if microphone != microphoneAccess { microphoneAccess = microphone }
    }
}

private typealias PermissionStatus = (title: String, symbol: String, tint: Color)

private struct PermissionRow<Icon: View>: View {
    let title: SettingsRowTitle
    let subtitle: String
    let status: PermissionStatus
    let buttonTitle: String
    let help: String
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        LabeledContent {
            HStack(spacing: Theme.Spacing.lg) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: status.symbol).accessibilityHidden(true)
                    Text(status.title)
                }
                .foregroundStyle(status.tint)
                Button(buttonTitle, action: action).help(help)
            }
        } label: {
            HStack(spacing: Theme.Spacing.lg) {
                icon
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    title
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PermissionSettingsIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: IconCache.icon(forFile: path))
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .id(IconCache.style.generation)
            .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
            .accessibilityHidden(true)
    }
}

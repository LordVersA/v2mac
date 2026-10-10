import SwiftUI
import UserNotifications

/// Which events post a notification (spec 12.8).
struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notifications = model.notifications
        Form {
            Section {
                switch notifications.authorization {
                case .denied:
                    LabeledContent {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } label: {
                        Text("Notifications are turned off")
                        Text("Allow them for V2Mac in System Settings → Notifications.")
                    }
                case .notDetermined:
                    LabeledContent("macOS has not been asked yet") {
                        Button("Allow Notifications…") { Task { await notifications.requestPermission() } }
                    }
                default:
                    LabeledContent("Notifications are allowed") {
                        Button("Send a Test") { notifications.sendTest() }
                    }
                }
            }
            Section {
                NotificationToggle(kind: .connection)
                NotificationToggle(kind: .reconnected)
                NotificationToggle(kind: .tun)
            } header: {
                Text("Connection")
            } footer: {
                note("\"Lost or failed\" covers a server that will not connect, a core that stopped and could not be restarted, and a busy port. These stay silent while a V2Mac window is in front.")
            }
            Section {
                NotificationToggle(kind: .expiry)
                NotificationToggle(kind: .traffic)
                NotificationToggle(kind: .updateFailed)
                NotificationToggle(kind: .serversChanged)
            } header: {
                Text("Subscriptions")
            } footer: {
                note("Expiry warns 3 days and 1 day ahead and when the date passes; traffic at 80%, 95% and 100% of the quota. Each warning is sent once. The last two apply to automatic updates only.")
            }
            Section("Updates") {
                NotificationToggle(kind: .appUpdate)
                NotificationToggle(kind: .coreUpdate)
            }
            Section {
                NotificationToggle(kind: .testFinished)
            } header: {
                Text("Tests")
            } footer: {
                note("Sent when a delay or speed test ends while V2Mac is in the background.")
            }
        }
        .formStyle(.grouped)
        .task { await notifications.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifications.refreshAuthorization() }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotificationToggle: View {
    let kind: NotificationKind
    @AppStorage private var isOn: Bool

    init(kind: NotificationKind) {
        self.kind = kind
        _isOn = AppStorage(wrappedValue: kind.defaultOn, kind.key)
    }

    var body: some View {
        Toggle(kind.title, isOn: $isOn)
    }
}

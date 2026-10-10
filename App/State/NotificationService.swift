import AppKit
import Observation
import UserNotifications

/// One switch in Settings → Notifications (spec 12.8). The raw value is part of the settings key.
enum NotificationKind: String, CaseIterable, Identifiable, Sendable {
    case connection, reconnected, tun
    case expiry, traffic, updateFailed, serversChanged
    case appUpdate, coreUpdate
    case testFinished

    var id: String { rawValue }
    var key: String { "notify_\(rawValue)" }

    var title: String {
        switch self {
        case .connection: "Connection lost or failed"
        case .reconnected: "Reconnected"
        case .tun: "TUN mode stopped"
        case .expiry: "Subscription expiring"
        case .traffic: "Traffic running out"
        case .updateFailed: "Automatic update failed"
        case .serversChanged: "Servers added or removed"
        case .appUpdate: "V2Mac update available"
        case .coreUpdate: "Xray core update available"
        case .testFinished: "Delay test finished"
        }
    }

    var defaultOn: Bool {
        switch self {
        case .connection, .tun, .expiry, .traffic, .appUpdate: true
        case .reconnected, .updateFailed, .serversChanged, .coreUpdate, .testFinished: false
        }
    }

    /// The window already shows these, so they stay out of the way while the app is in front.
    var isQuietWhileActive: Bool {
        switch self {
        case .connection, .reconnected, .tun, .testFinished: true
        default: false
        }
    }
}

/// Where a click on a notification leads.
enum WindowRequest: Equatable, Sendable {
    case main
    case settings(SettingsTab)

    var code: String {
        switch self {
        case .main: "main"
        case .settings(let tab): "settings:\(tab.rawValue)"
        }
    }

    init(code: String) {
        if code.hasPrefix("settings:"), let tab = SettingsTab(rawValue: String(code.dropFirst(9))) {
            self = .settings(tab)
        } else {
            self = .main
        }
    }
}

@MainActor @Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private static let portCategory = "port"
    private static let usePortAction = "usePort"

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Set by `AppModel`: open a window, and the "Use port" button.
    @ObservationIgnored var onOpen: @MainActor (WindowRequest) -> Void = { _ in }
    @ObservationIgnored var onUsePort: @MainActor () -> Void = {}

    private var center: UNUserNotificationCenter { .current() }

    /// Asks for permission the first time, so the first real notification is not lost to the prompt.
    func start() {
        center.delegate = self
        Task {
            await refreshAuthorization()
            if authorization == .notDetermined { await requestPermission() }
        }
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
    }

    /// `id` replaces an earlier notification with the same id instead of stacking another one.
    func post(_ kind: NotificationKind, title: String, body: String, id: String? = nil,
              open: WindowRequest = .main, usePort: Int? = nil) {
        guard Prefs.notify(kind) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["kind": kind.rawValue, "open": open.code]
        if let usePort {
            // The button's title carries the port, so the category is registered per notification.
            let action = UNNotificationAction(identifier: Self.usePortAction, title: "Use Port \(usePort)")
            center.setNotificationCategories([
                UNNotificationCategory(identifier: Self.portCategory, actions: [action], intentIdentifiers: []),
            ])
            content.categoryIdentifier = Self.portCategory
        }
        let request = UNNotificationRequest(identifier: id ?? UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            #if DEBUG
            print("[v2mac-debug] notification \(kind.rawValue): \(title) | \(body)\(error.map { " | error \($0)" } ?? "")")
            #endif
        }
    }

    /// The Settings button: goes out whatever the switches say.
    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "V2Mac"
        content.body = "Notifications are working."
        content.sound = .default
        content.userInfo = ["open": WindowRequest.settings(.notifications).code]
        center.add(UNNotificationRequest(identifier: "test", content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let raw = notification.request.content.userInfo["kind"] as? String
        let quiet = raw.flatMap(NotificationKind.init(rawValue:))?.isQuietWhileActive ?? false
        if quiet, await MainActor.run(body: { NSApp.isActive }) { return [.list] }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let open = response.notification.request.content.userInfo["open"] as? String ?? "main"
        await MainActor.run {
            if action == Self.usePortAction {
                onUsePort()
            } else if action == UNNotificationDefaultActionIdentifier {
                onOpen(WindowRequest(code: open))
            }
        }
    }
}

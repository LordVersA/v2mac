import AppKit
import Observation
import ServiceManagement
import SwiftData
import SwiftUI
import UserNotifications
import V2MacCore

enum SidebarItem: Hashable {
    case all
    case group(UUID)
}

@MainActor @Observable
final class AppModel {
    let container: ModelContainer
    let logs = LogStore()
    let connection: ConnectionController
    let subscriptions: SubscriptionService
    let latency: LatencyService
    let regionPacks = RegionPackService()
    let updates = UpdateService()
    let notifications = NotificationService()

    var sidebarSelection: SidebarItem = .all
    var selectedProfileIDs: Set<UUID> = []
    var searchText = ""
    var showAddSheet = false
    var addDraft = AddDraft()
    var showInspector = true
    var showRegionsSheet = false
    /// The Settings tab to show; the update buttons set it before opening Settings.
    var settingsTab: SettingsTab = .general
    /// A window a notification click asked for; `WindowRequestHandler` opens it.
    var windowRequest: WindowRequest?
    /// Rows currently shown in the server table (after search); the default test target.
    var visibleProfileIDs: [UUID] = []

    var context: ModelContext { container.mainContext }

    init() {
        Prefs.registerDefaults()
        AppPaths.prepare()
        #if DEBUG
        let demo = UserDefaults.standard.bool(forKey: "debugDemoData")
        let configuration = demo ? ModelConfiguration(isStoredInMemoryOnly: true) : ModelConfiguration(url: AppPaths.storeURL)
        #else
        let configuration = ModelConfiguration(url: AppPaths.storeURL)
        #endif
        do {
            container = try ModelContainer(for: ServerGroup.self, Profile.self, configurations: configuration)
        } catch {
            fatalError("Could not open the V2Mac database: \(error)")
        }
        connection = ConnectionController(logs: logs)
        subscriptions = SubscriptionService(container: container, connection: connection)
        latency = LatencyService(container: container)
        ensureManualGroup()
        let connection = self.connection
        latency.physicalInterface = { connection.tun.physicalInterface }
        let routes: () -> [FetchRoute] = {
            guard connection.isRunning else { return [.direct] }
            let inbound = Prefs.inbound
            return [.localProxy(port: connection.port, username: inbound.username, password: inbound.password), .direct]
        }
        regionPacks.downloadRoutes = routes
        regionPacks.onChangeInUse = { connection.reconnectIfRunning() }
        updates.downloadRoutes = routes
        updates.isCoreRunning = { connection.isRunning }
        updates.restartCore = { connection.reconnectIfRunning() }
        regionPacks.startScheduler()
        updates.startScheduler()
        Task { await updates.refreshCoreInfo() }
        let packs = regionPacks
        connection.regionRoutes = { packs.usableRoutes }
        #if DEBUG
        if demo {
            snapshotHook()
            seedDemoData()
            if UserDefaults.standard.bool(forKey: "debugFakeUpdates") { updates.fakeUpdates() }
            AppDelegate.model = self
            return
        }
        #endif
        wireNotifications()
        restoreActiveServer()
        if Prefs.reconnectOnLaunch, Prefs.wasRunning, connection.activeServer != nil {
            connection.connectActive()
        }
        subscriptions.startScheduler()
        AppDelegate.model = self
        #if DEBUG
        runDebugHooks()
        #endif
    }

    // MARK: Notifications

    /// Spec 12.8: every service reports events through a closure; the wording is decided here.
    private func wireNotifications() {
        let notifications = self.notifications
        let connection = self.connection
        notifications.onOpen = { [weak self] request in self?.windowRequest = request }
        notifications.onUsePort = { connection.useSuggestedPort() }

        connection.onNotice = { notice in
            // One id: the latest state of the connection replaces the one before it.
            switch notice {
            case .failed(let server, let message):
                notifications.post(.connection, title: "Could not connect", body: "\(server): \(message)", id: "connection")
            case .lost(let server):
                notifications.post(.connection, title: "Connection lost", body: "\(server) stopped and could not be restarted.", id: "connection")
            case .reconnected(let server):
                notifications.post(.reconnected, title: "Reconnected", body: "Connected to \(server) again.", id: "connection")
            case .portInUse(let busy, let suggested):
                notifications.post(
                    .connection, title: "Port \(busy) is in use",
                    body: suggested.map { "Another app is using it. V2Mac can use port \($0) instead." } ?? "Another app is using it. Choose another port in Settings.",
                    id: "connection", usePort: suggested
                )
            }
        }
        connection.tun.onFailure = { message in
            notifications.post(.tun, title: "TUN mode stopped", body: message, id: "tun")
        }

        subscriptions.onNotice = { notice in
            switch notice {
            case .updateFailed(let group, let message):
                notifications.post(.updateFailed, title: "Could not update \(group)", body: message, open: .settings(.servers))
            case .serversChanged(let group, let added, let removed, let activeRemoved):
                var parts: [String] = []
                if added > 0 { parts.append("\(added) added") }
                if removed > 0 { parts.append("\(removed) removed") }
                var body = parts.joined(separator: ", ") + "."
                if activeRemoved { body += " The server in use is no longer in the subscription." }
                notifications.post(.serversChanged, title: "\(group) was updated", body: body)
            case .expiry(let group, let level, let expiresAt):
                let body: String
                switch level {
                case .expired: body = "This subscription has expired."
                case .lastDay: body = "This subscription expires in less than a day."
                default: body = "This subscription expires in \(UsageAlert.daysLeft(expiresAt: expiresAt)) days."
                }
                notifications.post(.expiry, title: group, body: body)
            case .traffic(let group, let level, let used, let total):
                let amount = "\(ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)) used"
                let body = level == .out ? "The traffic quota is used up (\(amount))." : "\(Int(Double(used) / Double(total) * 100))% of the traffic quota is used (\(amount))."
                notifications.post(.traffic, title: group, body: body)
            }
        }

        updates.onFound = { found in
            // Once per release, not once per daily check.
            switch found {
            case .app(let tag):
                guard Prefs.announcedTag("notifiedAppTag") != tag else { return }
                Prefs.setAnnouncedTag(tag, "notifiedAppTag")
                notifications.post(.appUpdate, title: "V2Mac \(VersionCompare.normalized(tag)) is available", body: "Open Settings to install it.", id: "appUpdate", open: .settings(.general))
            case .core(let tag):
                guard Prefs.announcedTag("notifiedCoreTag") != tag else { return }
                Prefs.setAnnouncedTag(tag, "notifiedCoreTag")
                notifications.post(.coreUpdate, title: "Xray core \(tag) is available", body: "Open Settings to install it.", id: "coreUpdate", open: .settings(.core))
            }
        }

        latency.onFinished = { [weak self] tested, best in
            guard !NSApp.isActive else { return }
            let fastest = best.flatMap { best in self?.profile(id: best.id).map { "Fastest: \($0.name), \(best.ms) ms." } }
            notifications.post(
                .testFinished, title: "Test finished",
                body: "\(tested) \(tested == 1 ? "server" : "servers") tested. " + (fastest ?? "None answered."), id: "test"
            )
        }

        notifications.start()
    }

    // MARK: Active server

    private func restoreActiveServer() {
        guard let id = Prefs.activeProfileID, let profile = profile(id: id) else { return }
        connection.setActive(ActiveServer(profile))
    }

    func profile(id: UUID) -> Profile? {
        try? context.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })).first
    }

    func group(id: UUID) -> ServerGroup? {
        try? context.fetch(FetchDescriptor<ServerGroup>(predicate: #Predicate { $0.id == id })).first
    }

    func activate(_ profile: Profile) {
        guard let server = ActiveServer(profile) else { return }
        // A removed-upstream server is kept only while it is active (spec 6.4).
        let staleDescriptor = FetchDescriptor<Profile>(predicate: #Predicate { $0.isStale })
        for stale in (try? context.fetch(staleDescriptor)) ?? [] where stale.id != profile.id {
            context.delete(stale)
        }
        try? context.save()
        connection.activate(server)
    }

    func activate(profileID: UUID) {
        if let p = profile(id: profileID) { activate(p) }
    }

    // MARK: Groups

    /// The Custom Configs group is always in the sidebar, also before anything was pasted.
    private func ensureManualGroup() {
        let groups = (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        guard !groups.contains(where: \.isManual) else { return }
        // Kept ahead of the subscriptions, whose indexes start at 0.
        let group = ServerGroup(name: ServerGroup.manualName, subscriptionURL: "", sortIndex: -1)
        group.autoUpdateEnabled = false
        context.insert(group)
        try? context.save()
    }

    /// Deletes a subscription. The Custom Configs group only loses its servers and stays in the sidebar.
    func deleteGroup(_ group: ServerGroup) {
        if let active = connection.activeServer, group.profiles.contains(where: { $0.id == active.id }) {
            connection.disconnect()
            connection.setActive(nil)
        }
        if group.isManual {
            selectedProfileIDs.subtract(group.profiles.map(\.id))
            for profile in group.profiles { context.delete(profile) }
        } else {
            if sidebarSelection == .group(group.id) { sidebarSelection = .all }
            context.delete(group)
        }
        try? context.save()
    }

    /// ⌘V in the main window: configs are added straight away, a subscription URL opens the Add sheet.
    func pasteFromClipboard() {
        guard !showAddSheet,
              let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        if AddDraft.isSubscriptionURL(text) {
            addDraft = AddDraft(kind: .subscription)
            showAddSheet = true
            return
        }
        Task {
            do {
                sidebarSelection = .group(try await subscriptions.addCustom(text: text))
            } catch AddSubscriptionError.alreadyAdded {
                if let existing = try? context.fetch(FetchDescriptor<ServerGroup>()).first(where: \.isManual) {
                    sidebarSelection = .group(existing.id)
                }
            } catch {
                addDraft = AddDraft(kind: .custom, configText: text, error: error.localizedDescription)
                showAddSheet = true
            }
        }
    }

    /// Only pasted configs can be removed one by one; subscription servers follow their subscription.
    func deleteProfiles(_ ids: Set<UUID>) {
        let targets = ((try? context.fetch(FetchDescriptor<Profile>())) ?? [])
            .filter { ids.contains($0.id) && $0.group?.isManual == true }
        if let active = connection.activeServer, targets.contains(where: { $0.id == active.id }) {
            connection.disconnect()
            connection.setActive(nil)
        }
        selectedProfileIDs.subtract(ids)
        for profile in targets { context.delete(profile) }
        try? context.save()
    }

    func moveGroups(_ groups: [ServerGroup], from source: IndexSet, to destination: Int) {
        var reordered = groups
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, group) in reordered.enumerated() { group.sortIndex = index }
        try? context.save()
    }

    func updateSelection(viaProxy: Bool) {
        let selection = sidebarSelection
        Task {
            switch selection {
            case .all: await subscriptions.updateAll(viaProxy: viaProxy)
            case .group(let id): await subscriptions.update(groupID: id, viaProxy: viaProxy)
            }
        }
    }

    // MARK: Latency

    /// Selected rows, or every visible row when nothing is selected.
    func testTargets() -> [UUID] {
        selectedProfileIDs.isEmpty ? visibleProfileIDs : Array(selectedProfileIDs)
    }

    func testReal(_ ids: [UUID]? = nil) { latency.testReal(ids ?? testTargets()) }
    func testSpeed(_ ids: [UUID]? = nil) { latency.testSpeed(ids ?? testTargets()) }
    func testTCP(_ ids: [UUID]? = nil) { latency.testTCP(ids ?? testTargets()) }

    // MARK: Windows

    func openMainWindow(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }

    func openSettings(_ action: OpenSettingsAction, tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        NSApp.setActivationPolicy(.regular)
        action()
        NSApp.activate()
    }

    func openLogs(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "logs")
        NSApp.activate()
    }

    // MARK: Debug

    #if DEBUG
    /// `-debugDemoData YES`: in-memory store with made-up servers, for README screenshots.
    private func seedDemoData() {
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        let key = "jmsHqm9I9NJN3d3cZmhU6iM3sFM0q9D9p1tBvXkQm2E"
        let groups: [(String, Int64, Int64, Int, [(String, String, Int?)])] = [
            ("Example Cloud", 38, 100, 21, [
                ("🇩🇪 Frankfurt 01", "reality", 86), ("🇳🇱 Amsterdam 02", "ws", 112),
                ("🇫🇮 Helsinki 01", "reality", 143), ("🇹🇷 Istanbul 03", "ws", 61),
                ("🇦🇪 Dubai 01", "reality", 204), ("🇸🇪 Stockholm 01", "ws", nil),
                ("🇺🇸 New York 02", "ws", 267), ("🇬🇧 London 01", "reality", 98),
            ]),
            ("Demo VPN", 12, 50, 48, [
                ("🇫🇷 Paris 01", "ws", 121), ("🇯🇵 Tokyo 01", "reality", 231), ("🇨🇦 Toronto 01", "ws", 189),
            ]),
        ]
        for (gi, g) in groups.enumerated() {
            let group = ServerGroup(name: g.0, subscriptionURL: "https://sub.example.com/\(gi)", sortIndex: gi)
            group.usedBytes = g.1 * 1_073_741_824
            group.totalBytes = g.2 * 1_073_741_824
            group.expiresAt = Date().addingTimeInterval(Double(g.3) * 86_400)
            group.lastUpdatedAt = Date().addingTimeInterval(-1_800)
            context.insert(group)
            for (i, s) in g.4.enumerated() {
                let host = "node\(gi)\(i).example.com"
                let link = s.1 == "ws"
                    ? "vless://\(uuid)@\(host):443?type=ws&security=tls&sni=\(host)&path=%2Fws#\(s.0)"
                    : "vless://\(uuid)@\(host):443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=www.microsoft.com&fp=chrome&pbk=\(key)&sid=ab12#\(s.0)"
                guard let parsed = try? ShareLinkParser.parse(link) else { continue }
                let p = Profile(parsed: parsed, sortIndex: i, group: group)
                if let ms = s.2 {
                    p.delayState = .ok; p.delayMs = ms; p.delayKindRaw = "real"
                    p.speedBps = Double(40 + (i * 37) % 90) * 125_000
                } else {
                    p.delayState = .timeout; p.delayKindRaw = "real"
                }
                p.delayTestedAt = Date()
                context.insert(p)
            }
        }
        try? context.save()
    }

    /// `-debugSnapshot <path prefix>`: after `-debugSnapshotDelay` seconds (default 4) each open
    /// window draws itself, title bar and toolbar included, into `<prefix>-<n>.png`. The app
    /// renders its own views, so this needs no screen recording permission. Works with demo data.
    private func snapshotHook() {
        let defaults = UserDefaults.standard
        guard let prefix = defaults.string(forKey: "debugSnapshot") else { return }
        let delay = max(defaults.integer(forKey: "debugSnapshotDelay"), 4)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            let windows = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
            for (index, window) in windows.enumerated() {
                guard let view = window.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(index).png"))
            }
            print("[v2mac-debug] snapshot: \(windows.count) windows")
        }
    }

    /// `-debugAddSubscription <url> -debugActivateFirst YES` for scripted verification.
    private func runDebugHooks() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let defaults = UserDefaults.standard
        snapshotHook()
        if let packID = defaults.string(forKey: "debugEnablePack"), let pack = regionPacks.packs.first(where: { $0.id == packID }) {
            Task {
                await regionPacks.enable(pack)
                print("[v2mac-debug] pack \(packID): \(regionPacks.status(pack))")
                if defaults.bool(forKey: "debugActivateFirst") { connection.connectActive() }
            }
        }
        // `-debugLoginItem on|off|status`: the same calls as the "Launch at login" toggle.
        if let action = defaults.string(forKey: "debugLoginItem") {
            let service = SMAppService.mainApp
            do {
                if action == "on" { try service.register() }
                if action == "off" { try service.unregister() }
                print("[v2mac-debug] login item \(action): status \(service.status.rawValue)")
            } catch {
                print("[v2mac-debug] login item \(action) failed: \(error)")
            }
        }
        // `-debugWindowRequest <settings tab>|main`: what a click on a notification does.
        if let target = defaults.string(forKey: "debugWindowRequest") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                windowRequest = WindowRequest(code: target == "main" ? "main" : "settings:\(target)")
                try? await Task.sleep(for: .seconds(1))
                print("[v2mac-debug] window request handled: \(windowRequest == nil), settings tab \(settingsTab.rawValue)")
            }
        }
        // `-debugListDelivered <seconds>`: what Notification Center holds after that long.
        if defaults.integer(forKey: "debugListDelivered") > 0 {
            Task {
                try? await Task.sleep(for: .seconds(defaults.integer(forKey: "debugListDelivered")))
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications().map { "\($0.request.content.title): \($0.request.content.body)" }
                print("[v2mac-debug] delivered \(delivered.count): \(delivered.sorted().joined(separator: " / "))")
            }
        }
        // `-debugNotices YES`: one sample of every notification, through the same closures.
        if defaults.bool(forKey: "debugNotices") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                connection.onNotice(.failed(server: "Sample server", message: "sample reason"))
                connection.onNotice(.lost(server: "Sample server"))
                connection.onNotice(.reconnected(server: "Sample server"))
                connection.onNotice(.portInUse(busy: 10808, suggested: 10809))
                connection.tun.onFailure("Sample TUN failure.")
                subscriptions.onNotice(.updateFailed(group: "Sample", message: "sample reason"))
                subscriptions.onNotice(.serversChanged(group: "Sample", added: 2, removed: 1, activeRemoved: true))
                subscriptions.onNotice(.expiry(group: "Sample", level: .soon, expiresAt: Date().addingTimeInterval(2.5 * 86400)))
                subscriptions.onNotice(.traffic(group: "Sample", level: .low, used: 85 << 30, total: 100 << 30))
                updates.onFound(.app("v9.9.9"))
                updates.onFound(.core("v99.0.0"))
                latency.onFinished(12, nil)
                try? await Task.sleep(for: .seconds(4))
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.content.title)
                print("[v2mac-debug] notices: delivered \(delivered.count): \(delivered.sorted().joined(separator: " / "))")
            }
        }
        // `-debugNotify YES`: ask for permission and post one local notification.
        if defaults.bool(forKey: "debugNotify") {
            Task {
                let center = UNUserNotificationCenter.current()
                print("[v2mac-debug] notify: status before \(await center.notificationSettings().authorizationStatus.rawValue)")
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound])
                    print("[v2mac-debug] notify: granted \(granted), status \(await center.notificationSettings().authorizationStatus.rawValue)")
                    let content = UNMutableNotificationContent()
                    content.title = "V2Mac Dev"
                    content.body = "Test notification from the debug hook."
                    try await center.add(UNNotificationRequest(identifier: "debug-notify", content: content, trigger: nil))
                    try? await Task.sleep(for: .seconds(2))
                    print("[v2mac-debug] notify: posted, delivered \(await center.deliveredNotifications().count)")
                } catch {
                    print("[v2mac-debug] notify failed: \(error)")
                }
            }
        }
        if defaults.bool(forKey: "debugAppUpdate") {
            Task {
                await updates.checkApp(manual: true)
                print("[v2mac-debug] app check: \(updates.appStatus)")
                if case .available(let release) = updates.appStatus {
                    await updates.installApp(release)
                    // Only reached when the install failed; a successful one quits the app.
                    print("[v2mac-debug] app install: \(updates.appStatus)")
                }
            }
        }
        if let mode = defaults.string(forKey: "debugCoreUpdate") {
            Task {
                await updates.refreshCoreInfo()
                print("[v2mac-debug] core before: \(updates.coreVersion ?? "?")")
                await updates.checkCore()
                print("[v2mac-debug] check: \(updates.coreStatus)")
                var release: CoreRelease?
                if case .available(let r) = updates.coreStatus { release = r }
                if mode == "force", release == nil, let r = try? await CoreUpdater.discover(downloader: FileDownloader(routes: [.direct])) { release = r }
                if let release {
                    await updates.installCore(release)
                    print("[v2mac-debug] install: \(updates.coreStatus); version now \(updates.coreVersion ?? "?"); updatedCopy=\(updates.coreIsUpdatedCopy)")
                    if defaults.bool(forKey: "debugUpdateAll") {
            Task { await subscriptions.updateAll(viaProxy: false); print("[v2mac-debug] updateAll finished") }
        }
        if defaults.bool(forKey: "debugConnect") == false { connection.connectActive() }
                    try? await Task.sleep(for: .seconds(5))
                    print("[v2mac-debug] running core: \(AppPaths.coreExecutable.path)")
                    await updates.revertToBundled()
                    print("[v2mac-debug] reverted; version \(updates.coreVersion ?? "?"); updatedCopy=\(updates.coreIsUpdatedCopy)")
                }
            }
        }
        if defaults.bool(forKey: "debugConnect") { connection.connectActive() }
        if defaults.bool(forKey: "debugUseSuggestedPort") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                connection.useSuggestedPort()
            }
        }
        if defaults.bool(forKey: "debugSwitchTest") {
            // Connects to one share-link server, then picks another: the second should be a live switch.
            Task {
                let all = (try? context.fetch(FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
                let servers = all.filter { $0.kind == .outbound }.sorted { ($0.delayMs ?? .max) < ($1.delayMs ?? .max) }
                guard servers.count >= 2 else { print("[v2mac-debug] switch test: needs two share-link servers"); return }
                self.activate(servers[0])
                for _ in 0..<40 where !connection.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
                print("[v2mac-debug] switch test: first server up, running=\(connection.isRunning)")
                self.activate(servers[1])
                try? await Task.sleep(for: .seconds(2))
                print("[v2mac-debug] switch test: after second server, phase=\(connection.phase)")
            }
        }
        guard let url = defaults.string(forKey: "debugAddSubscription") else { return }
        let activate = defaults.bool(forKey: "debugActivateFirst")
        let testMode = defaults.string(forKey: "debugTest")
        let viaProxy = defaults.bool(forKey: "debugAddViaProxy")
        Task {
            if viaProxy {
                // Connect through an already-saved server first, as a user would.
                if let first = (try? context.fetch(FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.sortIndex)])))?.first { self.activate(first) }
                for _ in 0..<40 where !connection.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
                print("[v2mac-debug] core running for proxy fetch: \(connection.isRunning)")
            }
            do {
                let id = try await subscriptions.add(urlString: url, name: "", viaProxy: viaProxy)
                sidebarSelection = .group(id)
                logs.append("[v2mac] debug: added subscription")
                print("[v2mac-debug] added subscription")
            } catch {
                logs.append("[v2mac] debug: add failed: \(error.localizedDescription)")
                print("[v2mac-debug] add failed: \(error) | \(error.localizedDescription)")
            }
            if activate, let first = (try? context.fetch(FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.sortIndex)])))?.first {
                self.activate(first)
            }
            if let testMode {
                let ids = ((try? context.fetch(FetchDescriptor<Profile>())) ?? []).map(\.id)
                if testMode == "tcp" { latency.testTCP(ids) } else if testMode == "speed" { latency.testSpeed(ids) } else { latency.testReal(ids) }
            }
        }
    }
    #endif
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The main window opens on launch, so show the Dock icon until it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            let closing = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { AppDelegate.dockCheck(excluding: closing) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        Task { @MainActor in
            await model.connection.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Drop back to a menu-bar-only app once no regular window is left.
    private static func dockCheck(excluding closing: ObjectIdentifier?) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            let hasWindow = NSApp.windows.contains { w in
                ObjectIdentifier(w) != closing && w.isVisible && w.styleMask.contains(.titled) && !(w is NSPanel)
            }
            if !hasWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

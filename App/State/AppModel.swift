import AppKit
import Observation
import SwiftData
import SwiftUI
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

    var sidebarSelection: SidebarItem = .all
    var selectedProfileIDs: Set<UUID> = []
    var searchText = ""
    var showAddSheet = false
    var showInspector = true
    var showRegionsSheet = false
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
        let packs = regionPacks
        connection.regionRoutes = { packs.usableRoutes }
        #if DEBUG
        if demo { seedDemoData(); AppDelegate.model = self; return }
        #endif
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

    func deleteGroup(_ group: ServerGroup) {
        if let active = connection.activeServer, group.profiles.contains(where: { $0.id == active.id }) {
            connection.disconnect()
            connection.setActive(nil)
        }
        if sidebarSelection == .group(group.id) { sidebarSelection = .all }
        context.delete(group)
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

    func openSettings(_ action: OpenSettingsAction) {
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

    /// `-debugAddSubscription <url> -debugActivateFirst YES` for scripted verification.
    private func runDebugHooks() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let defaults = UserDefaults.standard
        if let packID = defaults.string(forKey: "debugEnablePack"), let pack = regionPacks.packs.first(where: { $0.id == packID }) {
            Task {
                await regionPacks.enable(pack)
                print("[v2mac-debug] pack \(packID): \(regionPacks.status(pack))")
                if defaults.bool(forKey: "debugActivateFirst") { connection.connectActive() }
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

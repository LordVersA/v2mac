import AppIntents
import AppKit
import CoreSpotlight
import Observation
import ServiceManagement
import SwiftData
import SwiftUI
import UserNotifications
import V2MacCore
import WidgetKit
import notify

enum SidebarItem: Hashable {
    case all
    case favorites
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
    let warp = WarpService()
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
    /// A custom rule the rule editor's Advanced mode scrolls to and lights up once.
    var focusedRule: UUID?
    /// The server editor's sheet (spec 12.7).
    var serverEditor: ServerEditorRequest?
    var cleanIPScan: CleanIPRequest?
    /// The Add sheet's "Enter Details Manually": the editor opens once that sheet has closed.
    var opensEditorAfterAddSheet = false
    /// A server the table should scroll to; `ServerTable` clears it once it has.
    var revealProfileID: UUID?
    /// Rows currently shown in the server table (after search); the default test target.
    var visibleProfileIDs: [UUID] = []
    /// Favorites a manual update found missing from their subscription; the main window asks
    /// whether to remove or keep them (spec 6.6).
    var missingFavoriteIDs: Set<UUID> = []

    /// Set when a change could not be written, so the main window says it will be lost.
    var saveError: String?

    var context: ModelContext { container.mainContext }

    func save() {
        do { try context.save() } catch {
            logs.append("[v2mac] Could not save changes: \(error.localizedDescription)")
            saveError = error.localizedDescription
        }
    }

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
        #if DEBUG
        // `-debugTunCancelled YES`: every TUN start acts as if the password prompt was closed.
        let tun = UserDefaults.standard.bool(forKey: "debugTunCancelled") ? TunController(logs: logs, authorize: { _ in .cancelled }) : nil
        connection = ConnectionController(logs: logs, tun: tun)
        #else
        connection = ConnectionController(logs: logs)
        #endif
        subscriptions = SubscriptionService(container: container, connection: connection)
        latency = LatencyService(container: container)
        ensureManualGroup()
        subscriptions.onMissingFavorites = { [weak self] ids in self?.missingFavoriteIDs.formUnion(ids) }
        let connection = self.connection
        latency.physicalInterface = { connection.testInterface }
        latency.beforeTesting = { hosts in await connection.killSwitch.allow(hosts) }
        connection.automaticCandidates = { [weak self] activeID in
            guard let self, let active = profile(id: activeID), let group = active.group else { return [] }
            return group.profiles.filter { !$0.isStale || $0.id == activeID }
                .sorted { $0.sortIndex == $1.sortIndex ? $0.id.uuidString < $1.id.uuidString : $0.sortIndex < $1.sortIndex }
                .compactMap { ActiveServer($0) }
        }
        let latencyStore = LatencyStore(modelContainer: container)
        connection.onAutomaticResults = { results in
            for result in results { try? await latencyStore.apply(id: result.id, outcome: result.outcome, kind: "real") }
        }
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
        warp.route = { routes()[0] }
        warp.onAccountChanged = { if UserDefaults.standard.bool(forKey: "warpExit") { connection.reconnectIfRunning() } }
        let subscriptions = subscriptions
        warp.addServer = { try await subscriptions.addCustom($0) }
        regionPacks.startScheduler()
        updates.startScheduler()
        Task { await updates.refreshCoreInfo() }
        let packs = regionPacks
        connection.regionRoutes = { packs.usableRoutes }
        #if DEBUG
        if demo {
            setvbuf(stdout, nil, _IOLBF, 0)
            snapshotHook()
            seedDemoData()
            revealHook()
            editorHook()
            windowRequestHook()
            backupHook()
            wireControls()
            if UserDefaults.standard.bool(forKey: "debugFakeUpdates") { updates.fakeUpdates() }
            AppDelegate.model = self
            return
        }
        #endif
        wireNotifications()
        restoreActiveServer()
        wireControls()
        watchServerIndex()
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

    /// Spec 12.6: every service reports events through a closure; the wording is decided here.
    private func wireNotifications() {
        let notifications = self.notifications
        let connection = self.connection
        notifications.onOpen = { [weak self] request in self?.windowRequest = request }
        notifications.onUsePort = { connection.useSuggestedPort() }

        connection.onNotice = { notice in
            // One id: the latest state of the connection replaces the one before it.
            switch notice {
            case .failed(let server, let message):
                notifications.post(.connection, title: String(localized: "Could not connect"), body: "\(server): \(message)", id: "connection")
            case .lost(let server):
                notifications.post(.connection, title: String(localized: "Connection lost"),
                                   body: String(localized: "\(server) stopped and could not be restarted."), id: "connection")
            case .reconnected(let server):
                notifications.post(.reconnected, title: String(localized: "Reconnected"), body: String(localized: "Connected to \(server) again."), id: "connection")
            case .portInUse(let busy, let suggested):
                notifications.post(
                    .connection, title: String(localized: "Port \(String(busy)) is in use"),
                    body: suggested.map { String(localized: "Another app is using it. V2Mac can use port \(String($0)) instead.") }
                        ?? String(localized: "Another app is using it. Choose another port in Settings."),
                    id: "connection", usePort: suggested
                )
            case .networkGone(let name):
                notifications.post(.network, title: String(localized: "Network disconnected"),
                                   body: String(localized: "\(NetworkInterfaces.describe(name).title) is no longer connected. V2Mac uses the automatic network again."),
                                   id: "network", open: .settings(.connection))
            }
        }
        connection.onTunFailure = { message in
            notifications.post(.tun, title: String(localized: "TUN mode stopped"), body: message, id: "tun")
        }

        subscriptions.onNotice = { notice in
            switch notice {
            case .updateFailed(let group, let message):
                notifications.post(.updateFailed, title: String(localized: "Could not update \(group)"), body: message, open: .settings(.servers))
            case .serversChanged(let group, let added, let removed, let activeRemoved):
                var parts: [String] = []
                if added > 0 { parts.append(String(localized: "\(added) added")) }
                if removed > 0 { parts.append(String(localized: "\(removed) removed")) }
                var body = parts.joined(separator: ", ") + "."
                if activeRemoved { body += " " + String(localized: "The server in use is no longer in the subscription.") }
                notifications.post(.serversChanged, title: String(localized: "\(group) was updated"), body: body)
            case .expiry(let group, let level, let expiresAt):
                let body: String
                switch level {
                case .expired: body = String(localized: "This subscription has expired.")
                case .lastDay: body = String(localized: "This subscription expires in less than a day.")
                default: body = String(localized: "This subscription expires in \(UsageAlert.daysLeft(expiresAt: expiresAt)) days.")
                }
                notifications.post(.expiry, title: group, body: body)
            case .traffic(let group, let level, let used, let total):
                let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)
                let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)
                let percent = Int(Double(used) / Double(total) * 100)
                let body = level == .out
                    ? String(localized: "The traffic quota is used up (\(usedText) of \(totalText) used).")
                    : String(localized: "\(percent)% of the traffic quota is used (\(usedText) of \(totalText) used).")
                notifications.post(.traffic, title: group, body: body)
            }
        }

        updates.onFound = { found in
            // Once per release, not once per daily check.
            switch found {
            case .app(let tag):
                guard Prefs.announcedTag("notifiedAppTag") != tag else { return }
                Prefs.setAnnouncedTag(tag, "notifiedAppTag")
                notifications.post(.appUpdate, title: String(localized: "V2Mac \(VersionCompare.normalized(tag)) is available"),
                                   body: String(localized: "Open Settings to install it."), id: "appUpdate", open: .settings(.general))
            }
        }

        updates.onHomebrewFailure = { message in
            notifications.post(.appUpdate, title: String(localized: "V2Mac was not updated"), body: message, id: "appUpdate", open: .settings(.general))
        }

        latency.onFinished = { [weak self] tested, best in
            guard !NSApp.isActive else { return }
            let fastest = best.flatMap { best in self?.profile(id: best.id).map { String(localized: "Fastest: \($0.name), \(best.ms) ms.") } }
            let count = tested == 1 ? String(localized: "1 server tested.") : String(localized: "\(tested) servers tested.")
            notifications.post(.testFinished, title: String(localized: "Test finished"),
                               body: count + " " + (fastest ?? String(localized: "None answered.")), id: "test")
        }

        notifications.start()
    }

    // MARK: Control Center

    /// Spec 12.4: the switch in Control Center and the menu bar asks through `ControlBridge`,
    /// and is told when the connection goes on or off.
    private func wireControls() {
        let connection = self.connection
        ControlBridge.handler = { on in
            switch (on, connection.phase) {
            case (true, .off), (true, .failed): connection.connectActive()
            case (false, .connecting), (false, .switching), (false, .connected): connection.disconnect()
            default: break
            }
        }
        var token: Int32 = 0
        notify_register_dispatch(ControlBridge.requestName, &token, .main) { _ in
            MainActor.assumeIsolated {
                if let connect = ControlBridge.pendingRequest() { ControlBridge.handler?(connect) }
            }
        }
        if let connect = ControlBridge.pendingRequest() { ControlBridge.handler?(connect) }
        publishControlState()
        publishWidgetStatus()
    }

    private func publishControlState() {
        withObservationTracking {
            let on: Bool
            switch connection.phase {
            case .connecting, .switching, .connected: on = true
            case .off, .failed: on = false
            }
            if on != ControlBridge.isConnected {
                ControlBridge.publish(connected: on)
                ControlCenter.shared.reloadControls(ofKind: ControlBridge.kind)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.publishControlState() }
        }
    }

    /// Spec 12.4: what the desktop widget shows besides on/off.
    private func publishWidgetStatus() {
        withObservationTracking {
            var exit = ""
            if case .known(let info) = connection.exit {
                exit = ([info.flag, info.city ?? info.countryCode].compactMap { $0 } + [info.ip]).joined(separator: " ")
            }
            let phase: ControlBridge.Status.Phase = switch connection.phase {
            case .off: .off
            case .connecting, .switching: .connecting
            case .connected: .connected
            case .failed: .failed
            }
            let status = ControlBridge.Status(phase: phase, server: connection.activeServer?.name ?? "", exit: exit)
            if status != ControlBridge.status {
                ControlBridge.status = status
                WidgetCenter.shared.reloadTimelines(ofKind: ControlBridge.widgetKind)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.publishWidgetStatus() }
        }
    }

    // MARK: Reset settings

    /// Spec 13: puts one Settings tab, or all of them, back to the defaults. Servers, rules, the
    /// WARP account, language, Keychain and Touch ID choices and the login item are kept.
    func resetSettings(_ tab: SettingsTab?) {
        let tabs = tab.map { [$0] } ?? SettingsTab.allCases
        for tab in tabs {
            // First, so the system-wide changes are undone the way their switches undo them.
            switch tab {
            case .proxy:
                connection.setSystemProxyEnabled(false)
                do { try Prefs.setProxyPassword("") } catch { logs.append("[v2mac] Could not clear the proxy password: \(error.localizedDescription)") }
            case .routing: connection.setRoutingMode(.global)
            case .connection: connection.setKillSwitchEnabled(false)
            default: break
            }
            for key in Prefs.resetKeys(tab) { UserDefaults.standard.removeObject(forKey: key) }
            if tab == .connection {
                connection.autoSelectionChanged()
                connection.tunFailurePolicyChanged()
            }
        }
        connection.reconnectIfRunning()
    }

    // MARK: Spotlight

    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexedServers: [ServerEntity]?

    /// Spec 12.4: servers in Spotlight and in Siri's phrases follow the list, a few seconds after
    /// a change is saved. Delay results are saved often too, so an unchanged list is not sent again.
    private func watchServerIndex() {
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleServerIndex() }
        }
        scheduleServerIndex()
    }

    private func scheduleServerIndex() {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            let servers = ServerEntity.all()
            guard servers != indexedServers else { return }
            indexedServers = servers
            let index = CSSearchableIndex.default()
            try? await index.deleteAppEntities(ofType: ServerEntity.self)
            try? await index.indexAppEntities(servers)
            V2MacShortcuts.updateAppShortcutParameters()
        }
    }

    // MARK: Active server

    private func restoreActiveServer() {
        guard let id = Prefs.activeProfileID, let profile = profile(id: id) else { return }
        connection.setActive(ActiveServer(profile))
    }

    /// Opens the list the active server belongs to, with its row selected and scrolled into view.
    func revealActiveServer() {
        if let id = connection.activeServer?.id { reveal(id) }
    }

    func reveal(_ id: UUID) {
        guard let profile = profile(id: id) else { return }
        // A search could be hiding the row.
        searchText = ""
        sidebarSelection = profile.group.map { .group($0.id) } ?? .all
        selectedProfileIDs = [id]
        revealProfileID = id
    }

    func profile(id: UUID) -> Profile? {
        try? context.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })).first
    }

    func group(id: UUID) -> ServerGroup? {
        try? context.fetch(FetchDescriptor<ServerGroup>(predicate: #Predicate { $0.id == id })).first
    }

    func activate(_ profile: Profile) {
        guard let server = ActiveServer(profile) else { return }
        // A removed-upstream server is kept only while it is active or a favorite (spec 6.4).
        let staleDescriptor = FetchDescriptor<Profile>(predicate: #Predicate { $0.isStale && !$0.isFavorite })
        for stale in (try? context.fetch(staleDescriptor)) ?? [] where stale.id != profile.id {
            context.delete(stale)
        }
        save()
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
        save()
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
        save()
    }

    /// ⌘V in the main window: text, or a picture with QR codes in it (a screenshot).
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string) {
            importText(text)
        } else if let image = NSImage(pasteboard: pasteboard) {
            importImage(image)
        }
    }

    /// A file dropped on the window or opened with V2Mac: a backup, configs as text, or a picture
    /// of QR codes.
    func importFile(_ url: URL) {
        if url.pathExtension.lowercased() == Backup.fileExtension { return BackupFlow.restore(self, from: url) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size < 5_000_000 else { return }
        if let image = NSImage(contentsOf: url), image.isValid {
            importImage(image)
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            importText(text)
        }
    }

    private func importImage(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let found = QRCodeReader.messages(in: cgImage)
        if found.isEmpty {
            addDraft = AddDraft(kind: .custom, error: String(localized: "No QR code was found in the picture."))
            showAddSheet = true
        } else {
            importText(found.joined(separator: "\n"))
        }
    }

    /// A link opened from another app: `v2mac://install-config?url=<subscription>&name=<name>`
    /// from a provider's page, or a server's share link (`vless://…`). Both open the Add sheet
    /// filled in, so nothing is added without the user seeing it.
    func open(_ url: URL) {
        // From the Control Center switch while V2Mac was not running (`ControlBridge`).
        if url.scheme?.lowercased() == "v2mac", url.host() == "connect" {
            if case .off = connection.phase { connection.connectActive() }
            return
        }
        windowRequest = .main
        if url.isFileURL { return importFile(url) }
        guard !showAddSheet else { return }
        if url.scheme?.lowercased() == "v2mac" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let link = items.first(where: { $0.name == "url" })?.value, AddDraft.isSubscriptionURL(link) else { return }
            addDraft = AddDraft(kind: .subscription, url: link, name: items.first { $0.name == "name" }?.value ?? "")
        } else {
            addDraft = AddDraft(kind: .custom, configText: url.absoluteString)
        }
        showAddSheet = true
    }

    /// Configs are added straight away; a subscription URL opens the Add sheet with it filled in.
    func importText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !showAddSheet, !text.isEmpty else { return }
        if AddDraft.isSubscriptionURL(text) {
            addDraft = AddDraft(kind: .subscription, url: text)
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

    // MARK: Backup

    /// Spec 12.9: subscriptions with their servers, pasted configs, favorites and settings.
    func makeBackup() -> Backup {
        let groups = (try? context.fetch(FetchDescriptor<ServerGroup>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        let defaults = UserDefaults.standard
        var settings = Dictionary(uniqueKeysWithValues: Prefs.backupKeys.compactMap { key in
            defaults.object(forKey: key).flatMap(Backup.json(fromPreference:)).map { (key, $0) }
        })
        settings["enabledRegionPacks"] = .array(regionPacks.enabledIDs.sorted().map { .string($0) })
        return Backup(app: Prefs.appVersion, groups: groups.map { group in
            let profiles = group.profiles.filter { !$0.isStale || $0.isFavorite }.sorted { $0.sortIndex < $1.sortIndex }
            return Backup.Group(
                name: group.name, subscriptionURL: group.subscriptionURL, autoUpdate: group.autoUpdateEnabled,
                intervalHours: group.serverIntervalHours, color: group.colorName, userAgent: group.userAgent,
                servers: profiles.compactMap { p in
                    p.config.map { config in
                        Backup.Server(profile: ParsedProfile(
                            name: p.name, kind: p.kind, protocolName: p.protocolName, address: p.address, port: p.port,
                            transport: p.transport, security: p.security, config: config, originalLink: p.originalLink, warnings: p.warnings
                        ), favorite: p.isFavorite)
                    }
                }
            )
        }, settings: settings)
    }

    /// Adds what the backup has and this Mac does not: subscriptions it lacks come with their
    /// servers, so they work before their first update; a subscription that is already here
    /// only gets its favorites back; pasted configs are added unless they are here. Settings are
    /// taken from the backup. Returns the subscriptions and servers added.
    @discardableResult
    func restore(_ backup: Backup) -> (groups: Int, servers: Int) {
        let existing = (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        var nextIndex = (existing.map(\.sortIndex).max() ?? -1) + 1
        var added = (groups: 0, servers: 0)
        for item in backup.groups {
            let group: ServerGroup
            if let match = existing.first(where: { $0.subscriptionURL == item.subscriptionURL }) {
                group = match
            } else {
                group = ServerGroup(name: item.name, subscriptionURL: item.subscriptionURL, sortIndex: nextIndex)
                group.autoUpdateEnabled = item.autoUpdate
                group.serverIntervalHours = item.intervalHours
                group.colorName = item.color
                group.userAgent = item.userAgent
                context.insert(group)
                nextIndex += 1
                added.groups += 1
            }
            let known = Dictionary(group.profiles.map { ($0.fingerprint, $0) }, uniquingKeysWith: { first, _ in first })
            let addsServers = group.isManual || group.profiles.isEmpty
            var index = (group.profiles.map(\.sortIndex).max() ?? -1) + 1
            for server in item.servers {
                if let profile = known[server.profile.fingerprint] {
                    if server.favorite { profile.isFavorite = true }
                } else if addsServers {
                    let profile = Profile(parsed: server.profile, sortIndex: index, group: group)
                    profile.isFavorite = server.favorite
                    context.insert(profile)
                    index += 1
                    added.servers += 1
                }
            }
        }
        save()

        let allowed = Set(Prefs.backupKeys)
        for (key, value) in backup.settings where allowed.contains(key) {
            if let preference = Backup.preference(from: value) { UserDefaults.standard.set(preference, forKey: key) }
        }
        Prefs.migrateCustomRules()
        let packs = Set(backup.settings["enabledRegionPacks"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        for pack in regionPacks.packs where packs.contains(pack.id) && !regionPacks.enabledIDs.contains(pack.id) {
            Task { await regionPacks.enable(pack) }
        }
        // State objects that keep a setting of their own take the restored one.
        connection.setRoutingMode(Prefs.routingMode)
        connection.setTunEnabled(Prefs.tunEnabled)
        connection.setSystemProxyEnabled(Prefs.systemProxy)
        connection.setKillSwitchEnabled(Prefs.killSwitch)
        connection.reconnectIfRunning()
        return added
    }

    // MARK: Server editor

    /// Pasted configs are changed in place. A subscription's server would be replaced by the
    /// next update, so the editor saves a copy of it instead.
    func editServer(_ id: UUID) {
        guard let profile = profile(id: id) else { return }
        serverEditor = ServerEditorRequest(target: profile.group?.isManual == true ? .edit(id) : .copy(id))
    }

    func saveServer(_ parsed: ParsedProfile, target: ServerEditorRequest.Target) {
        switch target {
        case .edit(let id):
            guard let profile = profile(id: id) else { return }
            profile.edit(from: parsed)
            save()
            if connection.activeServer?.id == id, let server = ActiveServer(profile) {
                connection.setActive(server)
                connection.reconnectIfRunning()
            }
        case .new, .copy:
            guard let group = (try? context.fetch(FetchDescriptor<ServerGroup>()))?.first(where: \.isManual) else { return }
            let profile = Profile(parsed: parsed, sortIndex: (group.profiles.map(\.sortIndex).max() ?? -1) + 1, group: group)
            context.insert(profile)
            save()
            searchText = ""
            sidebarSelection = .group(group.id)
            selectedProfileIDs = [profile.id]
            revealProfileID = profile.id
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
        save()
    }

    // MARK: Favorites

    func setFavorite(_ ids: Set<UUID>, _ favorite: Bool) {
        let targets = ((try? context.fetch(FetchDescriptor<Profile>())) ?? []).filter { ids.contains($0.id) }
        for profile in targets {
            profile.isFavorite = favorite
            if !favorite { releaseFavorite(profile) }
        }
        save()
    }

    /// Answers the question about favorites their subscription dropped: remove them, or keep
    /// them and stop asking.
    func resolveMissingFavorites(remove: Bool) {
        let ids = missingFavoriteIDs
        missingFavoriteIDs = []
        // One that came back in a later update is no longer part of the question.
        let targets = ((try? context.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.isFavorite && $0.isStale }))) ?? [])
            .filter { ids.contains($0.id) }
        for profile in targets {
            if remove {
                profile.isFavorite = false
                releaseFavorite(profile)
            } else {
                profile.keptAfterRemoval = true
            }
        }
        save()
    }

    /// A server its subscription dropped was only there as a favorite: it goes with the star,
    /// unless it is the one in use (spec 6.4).
    private func releaseFavorite(_ profile: Profile) {
        profile.keptAfterRemoval = false
        missingFavoriteIDs.remove(profile.id)
        guard profile.isStale, profile.id != connection.activeServer?.id else { return }
        selectedProfileIDs.remove(profile.id)
        context.delete(profile)
    }

    func moveGroups(_ groups: [ServerGroup], from source: IndexSet, to destination: Int) {
        var reordered = groups
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, group) in reordered.enumerated() { group.sortIndex = index }
        save()
    }

    func updateSelection(viaProxy: Bool) {
        let selection = sidebarSelection
        Task {
            switch selection {
            case .all, .favorites: await subscriptions.updateAll(viaProxy: viaProxy)
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

    /// Spec 12.4: the real delay of a group's servers, or of all, for Shortcuts actions. Fastest
    /// first, only those that answered; the results show in the list too.
    func measureDelays(groupID: UUID?) async -> [(id: UUID, ms: Int)] {
        let profiles = (try? context.fetch(FetchDescriptor<Profile>())) ?? []
        let targets = profiles.filter { !$0.isStale && (groupID == nil || $0.group?.id == groupID) }
            .compactMap { p in p.config.map { LatencyTarget(id: p.id, config: $0, kind: p.kind) } }
        await latency.beforeTesting(targets.flatMap { KillSwitch.hosts(in: $0.config, kind: $0.kind) })
        let collector = AutomaticLatencyResults()
        await latency.tester(options: Prefs.latencyOptions).run(targets) { await collector.append($0) }
        let store = LatencyStore(modelContainer: container)
        var answered: [(id: UUID, ms: Int)] = []
        for result in await collector.results {
            try? await store.apply(id: result.id, outcome: result.outcome, kind: "real")
            if case .ok(let ms) = result.outcome { answered.append((result.id, ms)) }
        }
        return answered.sorted { $0.ms < $1.ms }
    }

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

    func openRuleBuilder(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: RuleBuilderView.windowID)
        NSApp.activate()
    }

    func openRuleEditor(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: RuleEditorView.windowID)
        NSApp.activate()
    }

    func openConnections(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: ConnectionsView.windowID)
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
            group.supportURL = "https://example.com/support"
            group.webPageURL = "https://example.com/account"
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
                p.isFavorite = i == 0 || (gi == 0 && i == 3)
                context.insert(p)
                // `-debugMissingFavorites YES`: one favorite its subscription dropped, with the question showing.
                if gi == 1, i == 0, UserDefaults.standard.bool(forKey: "debugMissingFavorites") {
                    p.isStale = true
                    missingFavoriteIDs.insert(p.id)
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "debugShowFavorites") { sidebarSelection = .favorites }
        save()
        // `-debugSelect <part of a name>`: that server selected, so the inspector shows it.
        if let part = UserDefaults.standard.string(forKey: "debugSelect"),
           let match = (try? context.fetch(FetchDescriptor<Profile>()))?.first(where: { $0.name.contains(part) }) {
            selectedProfileIDs = [match.id]
        }
        // `-debugActivateFirst YES`: an active server, so the bar and the menu bar panel are filled in.
        if UserDefaults.standard.bool(forKey: "debugActivateFirst"),
           let first = (try? context.fetch(FetchDescriptor<Profile>()))?.first(where: { $0.name.contains("Frankfurt") }) {
            // Two earlier connections, so the panel's "Recent" list has rows.
            for name in ["Tokyo", "Paris"] {
                if let p = (try? context.fetch(FetchDescriptor<Profile>()))?.first(where: { $0.name.contains(name) }) { connection.noteRecent(p.id) }
            }
            activate(first)
        }
        if UserDefaults.standard.bool(forKey: "debugFakeRates") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                connection.fakeRates()
            }
        }
    }

    /// `-debugDemoData YES -debugRevealActive YES`: a long list whose last server is the active
    /// one, then what a click on the server name in the connection bar does.
    private func revealHook() {
        guard UserDefaults.standard.bool(forKey: "debugRevealActive") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            try? await Task.sleep(for: .seconds(2))
            let groups = (try? context.fetch(FetchDescriptor<ServerGroup>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
            guard let group = groups.first(where: { !$0.profiles.isEmpty }),
                  let template = group.profiles.first?.originalLink.flatMap({ try? ShareLinkParser.parse($0) }) else { return }
            // `-debugRevealRow <n>` picks another filler row than the last.
            let target = UserDefaults.standard.string(forKey: "debugRevealRow").flatMap(Int.init) ?? 59
            var last: Profile?
            for i in 0..<60 {
                let p = Profile(parsed: template, sortIndex: 100 + i, group: group)
                p.name = "Filler \(i)"
                context.insert(p)
                if i == target { last = p }
            }
            save()
            connection.setActive(last.flatMap(ActiveServer.init))
            revealActiveServer()
            print("[v2mac-debug] reveal: sidebar \(sidebarSelection), selected \(selectedProfileIDs.count)")
        }
    }

    /// `-debugDemoData YES -debugEditServer new|<row>`: opens the server editor empty, or on that
    /// row of the first subscription.
    private func editorHook() {
        guard let target = UserDefaults.standard.string(forKey: "debugEditServer") else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            let groups = (try? context.fetch(FetchDescriptor<ServerGroup>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
            let rows = groups.first { !$0.profiles.isEmpty }?.profiles.sorted { $0.sortIndex < $1.sortIndex } ?? []
            if let index = Int(target), rows.indices.contains(index) {
                editServer(rows[index].id)
            } else if target == "save", let first = rows.first, let config = first.config,
                      var draft = ServerDraft(outbound: config, name: first.name) {
                // What Save does with a subscription's server, then with the copy it made.
                setvbuf(stdout, nil, _IOLBF, 0)
                draft.name = "Edited Copy"
                draft.muxEnabled = true
                guard let parsed = try? draft.profile() else { return }
                saveServer(parsed, target: .copy(first.id))
                guard let copyID = selectedProfileIDs.first, let copy = profile(id: copyID) else { return }
                print("[v2mac-debug] editor: copy in \(copy.group?.name ?? "?"), mux \(copy.config?["mux"]?["enabled"]?.boolValue == true), link \(copy.originalLink != nil)")
                draft.name = "Edited Twice"
                draft.transport = "ws"
                draft.path = "/edited"
                guard let again = try? draft.profile() else { return }
                saveServer(again, target: .edit(copyID))
                print("[v2mac-debug] editor: now \(copy.name), \(copy.typeSummary), same row \(copy.id == copyID), rows \(copy.group?.profiles.count ?? 0)")
            } else {
                serverEditor = ServerEditorRequest(target: .new)
            }
        }
    }

    /// `-debugDemoData YES -debugBackupRoundTrip <path>`: writes a backup there, removes every
    /// server, restores the file, and prints what came back.
    private func backupHook() {
        guard let path = UserDefaults.standard.string(forKey: "debugBackupRoundTrip") else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            @MainActor func counts() -> String {
                let groups = (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? []
                let profiles = (try? context.fetch(FetchDescriptor<Profile>())) ?? []
                return "\(groups.count) groups, \(profiles.count) servers, \(profiles.filter(\.isFavorite).count) favorites"
            }
            let before = counts()
            do {
                try makeBackup().fileData().write(to: URL(fileURLWithPath: path))
                for group in (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? [] where !group.isManual { context.delete(group) }
                save()
                let emptied = counts()
                let added = restore(try Backup.read(Data(contentsOf: URL(fileURLWithPath: path))))
                print("[v2mac-debug] backup: before \(before); emptied \(emptied); added \(added.groups) groups, \(added.servers) servers; after \(counts())")
                let again = restore(try Backup.read(Data(contentsOf: URL(fileURLWithPath: path))))
                print("[v2mac-debug] backup: restored twice adds \(again.groups) groups, \(again.servers) servers; \(counts())")
            } catch {
                print("[v2mac-debug] backup failed: \(error)")
            }
        }
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
            // Titled windows, the menu bar item (its own small window) and its panel when open.
            let windows = NSApp.windows.filter {
                $0.isVisible && ($0.styleMask.contains(.titled) || $0.className.contains("StatusBar") || $0.frame.width >= 200)
            }
            for (index, window) in windows.enumerated() {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let png = rep.representation(using: .png, properties: [:])
                try? png?.write(to: URL(fileURLWithPath: "\(prefix)-\(index).png"))
            }
            // Frames in screen points from the top left, as synthetic clicks and System Events use them.
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let frames = windows.map { "\(Int($0.frame.minX)),\(Int(top - $0.frame.maxY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
            print("[v2mac-debug] snapshot: \(windows.count) windows: \(frames.joined(separator: " | "))")
            print("[v2mac-debug] layout \(NSApp.userInterfaceLayoutDirection == .rightToLeft ? "rtl" : "ltr"), localizations \(Bundle.main.preferredLocalizations)")
        }
    }

    /// `-debugWindowRequest <settings tab>|main|rule-builder`: what a click on a notification does. Works with
    /// demo data, so `-debugSnapshot` can show a settings tab.
    private func windowRequestHook() {
        guard let target = UserDefaults.standard.string(forKey: "debugWindowRequest") else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            windowRequest = WindowRequest(code: ["main", RuleBuilderView.windowID, RuleEditorView.windowID, ConnectionsView.windowID].contains(target) ? target : "settings:\(target)")
            try? await Task.sleep(for: .seconds(1))
            print("[v2mac-debug] window request handled: \(windowRequest == nil), settings tab \(settingsTab.rawValue)")
        }
    }

    /// `-debugAddSubscription <url> -debugActivateFirst YES` for scripted verification.
    private func runDebugHooks() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let defaults = UserDefaults.standard
        snapshotHook()
        // `-debugIntent servers|test|fastest|exit`: runs that Shortcuts action and prints what it found.
        if let name = defaults.string(forKey: "debugIntent") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                switch name {
                case "servers":
                    let groups = (try? await GroupQuery().suggestedEntities()) ?? []
                    let matches = (try? await ServerQuery().entities(matching: String(ServerEntity.all().first?.name.prefix(4) ?? ""))) ?? []
                    print("[v2mac-debug] intent servers: \(ServerEntity.all().count), groups: \(groups.map(\.name)), matching: \(matches.count)")
                case "test":
                    let results = await measureDelays(groupID: nil)
                    print("[v2mac-debug] intent test: \(results.count) answered, fastest \(results.first.map { "\($0.ms) ms" } ?? "none")")
                case "fastest":
                    _ = try? await ConnectToFastestIntent().perform()
                    print("[v2mac-debug] intent fastest: active \(connection.activeServer?.name ?? "none")")
                case "exit":
                    _ = try? await GetExitIPIntent().perform()
                    print("[v2mac-debug] intent exit: \(connection.exit)")
                default: break
                }
            }
        }
        // `-debugCleanIP YES|<transport>` opens Find Clean IP on the first server it applies to.
        if let wanted = defaults.string(forKey: "debugCleanIP") {
            let all = (try? context.fetch(FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
            if let first = all.first(where: { $0.kind == .outbound && $0.config.flatMap(CleanIPScanner.hostName(of:)) != nil && (wanted == "YES" || $0.transport == wanted) }) {
                windowRequest = .main
                cleanIPScan = CleanIPRequest(id: first.id)
            }
        }
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
        windowRequestHook()
        // `-debugQueueTests <part of a subscription name>`: a speed test of that subscription, then a
        // real delay test of every other server asked for while it runs, as from the menu bar and
        // then the window. Prints the live speed and what the tests left in the store.
        if let groupName = defaults.string(forKey: "debugQueueTests") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                let all = (try? container.mainContext.fetch(FetchDescriptor<Profile>())) ?? []
                let first = all.filter { $0.group?.name.localizedCaseInsensitiveContains(groupName) == true }
                let rest = all.filter { p in !first.contains { $0.id == p.id } }.map(\.id)
                latency.testSpeed(first.map(\.id))
                try? await Task.sleep(for: .milliseconds(300))
                latency.testReal(rest)
                print("[v2mac-debug] queued: speed \(first.count), real \(rest.count), total \(latency.total)")
                var last: LatencyService.LiveSpeed?
                while latency.isRunning {
                    if latency.liveSpeed != last {
                        last = latency.liveSpeed
                        if let live = last { print("[v2mac-debug] live \(live.id.uuidString.prefix(8)): \(live.bps.map(Format.rate) ?? "connecting")") }
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let states = ((try? container.mainContext.fetch(FetchDescriptor<Profile>())) ?? []).map { "\($0.delayState.rawValue)\($0.speedBps.map { "+" + Format.rate($0) } ?? "")" }
                print("[v2mac-debug] after run: \(Dictionary(grouping: states) { $0 }.mapValues(\.count))")
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
                connection.onNotice(.networkGone(name: "en9"))
                connection.tun.onFailure("Sample TUN failure.")
                subscriptions.onNotice(.updateFailed(group: "Sample", message: "sample reason"))
                subscriptions.onNotice(.serversChanged(group: "Sample", added: 2, removed: 1, activeRemoved: true))
                subscriptions.onNotice(.expiry(group: "Sample", level: .soon, expiresAt: Date().addingTimeInterval(2.5 * 86400)))
                subscriptions.onNotice(.traffic(group: "Sample", level: .low, used: 85 << 30, total: 100 << 30))
                updates.onFound(.app("v9.9.9"))
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
        // `-debugAddCustom YES`: a few made-up servers of different protocols in Custom Configs, for
        // trying the lists by hand with the dev build's own data. They do not connect anywhere.
        if defaults.bool(forKey: "debugAddCustom") {
            let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
            let key = "jmsHqm9I9NJN3d3cZmhU6iM3sFM0q9D9p1tBvXkQm2E"
            let links = [
                "vless://\(uuid)@custom1.example.com:443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=www.microsoft.com&fp=chrome&pbk=\(key)&sid=ab12#🇩🇪 Custom Berlin",
                "vless://\(uuid)@custom2.example.com:443?type=ws&security=tls&sni=custom2.example.com&path=%2Fws#🇳🇱 Custom Amsterdam",
                "trojan://demo-password@custom3.example.com:443?security=tls&sni=custom3.example.com&type=tcp#🇫🇷 Custom Paris",
                "ss://YWVzLTI1Ni1nY206ZGVtby1wYXNzd29yZA@custom4.example.com:8388#🇯🇵 Custom Tokyo",
            ]
            Task {
                do {
                    sidebarSelection = .group(try await subscriptions.addCustom(text: links.joined(separator: "\n")))
                    print("[v2mac-debug] added custom servers")
                } catch {
                    print("[v2mac-debug] add custom failed: \(error)")
                }
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

    /// Share links and `v2mac://` links clicked in other apps, and files opened with V2Mac.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Self.model?.open(url) }
    }

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

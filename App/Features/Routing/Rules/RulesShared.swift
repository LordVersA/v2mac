import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import V2MacCore

/// What the Rules window looks things up in: the core's geo lists (names and contents) and the apps
/// on this Mac. Read once, off the main actor.
@MainActor @Observable
final class RuleCatalog {
    private(set) var geo = GeoCatalog()
    private(set) var apps: [InstalledApp] = []
    /// Every list's contents, for the smart field and the tester.
    private(set) var lists = GeoLists()
    private var loading = false
    /// Goes up each time `lists` is replaced.
    @ObservationIgnored private(set) var version = 0

    func load() async {
        guard !geo.isLoaded, !loading else { return }
        loading = true
        let assets = AppPaths.assetsDirectory
        async let catalog = GeoCatalog.load()
        async let installed = InstalledApps.all()
        async let contents = Task.detached { GeoLists(folders: [assets]) }.value
        (geo, apps, lists) = await (catalog, installed, contents)
        version += 1
        loading = false
    }

    /// Region packs and core updates change the files.
    func reload() async {
        geo = GeoCatalog()
        await load()
    }
}

extension Rule.Action {
    var symbol: String {
        switch self {
        case .proxy: "lock.shield.fill"
        case .direct: "arrow.right.circle.fill"
        case .block: "nosign"
        case .via: "arrow.triangle.turn.up.right.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .proxy: .blue
        case .direct: .green
        case .block: .red
        case .via: .purple
        }
    }

    /// "Proxy", or "Via Work" with the target's current name.
    @MainActor func title(_ model: AppModel) -> String {
        switch self {
        case .proxy: String(localized: "Proxy")
        case .direct: String(localized: "Direct")
        case .block: String(localized: "Block")
        case .via(let via): String(localized: "Via \(model.viaName(via.target) ?? via.name)")
        }
    }
}

extension AppModel {
    /// The Via target's name now, or nil when its server or group is gone.
    func viaName(_ target: Rule.Via.Target) -> String? {
        switch target {
        case .server(let id): profile(id: id)?.name
        case .group(let id): group(id: id)?.name
        }
    }

    /// Imported Via rules name targets from another Mac: each is matched to a server or group of
    /// the same name here, and left unresolved (failing closed) when there is none.
    func resolvingVia(_ rules: [Rule]) -> [Rule] {
        let groups = (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        let servers = (try? context.fetch(FetchDescriptor<Profile>())) ?? []
        return rules.map { rule in
            guard case .via(var via) = rule.action, viaName(via.target) == nil else { return rule }
            switch via.target {
            case .group: if let g = groups.first(where: { $0.name == via.name }) { via.target = .group(g.id) }
            case .server: if let p = servers.first(where: { $0.name == via.name && !$0.isStale }) { via.target = .server(p.id) }
            }
            var out = rule
            out.action = .via(via)
            return out
        }
    }
}

extension Rule {
    /// "3 apps, 12 domains", for rows and lists.
    var itemSummary: String {
        let counts = Dictionary(grouping: items, by: \.kind.group).mapValues(\.count)
        let parts = Rule.Item.Kind.Group.allCases.compactMap { group in counts[group].map { group.count($0) } }
        return parts.isEmpty ? (only.isEmpty ? String(localized: "Nothing yet") : String(localized: "All traffic")) : parts.formatted(.list(type: .and, width: .narrow))
    }

    /// "Port 443 · UDP · QUIC · Safari", empty without conditions.
    var onlySummary: String {
        var parts: [String] = []
        if !only.ports.isEmpty { parts.append(String(localized: "Port \(only.ports)")) }
        if let network = only.network { parts.append(network.rawValue.uppercased()) }
        parts += only.protocols.map(\.title)
        parts += only.apps
        return parts.joined(separator: " · ")
    }
}

extension Rule.Sniffed {
    var title: String {
        switch self {
        case .bittorrent: "BitTorrent"
        case .quic: "QUIC"
        case .tls: "TLS"
        case .http: "HTTP"
        }
    }
}

extension Rule.Item.Kind {
    /// How tokens are grouped in the detail.
    enum Group: Int, CaseIterable, Comparable {
        case apps, domains, ips, countries, services, invalid

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .apps: "Apps"
            case .domains: "Domains"
            case .ips: "IP Addresses"
            case .countries: "Countries"
            case .services: "Services"
            case .invalid: "Not Understood"
            }
        }

        func count(_ n: Int) -> String {
            switch self {
            case .apps: String(localized: "\(n) apps")
            case .domains: String(localized: "\(n) domains")
            case .ips: String(localized: "\(n) addresses")
            case .countries: String(localized: "\(n) countries")
            case .services: String(localized: "\(n) services")
            case .invalid: String(localized: "\(n) not understood")
            }
        }
    }

    var group: Group {
        switch self {
        case .app: .apps
        case .domain, .exact, .keyword, .regex: .domains
        case .ip: .ips
        case .country: .countries
        case .service: .services
        case .invalid: .invalid
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .app: "App"
        case .domain: "Domain and subdomains"
        case .exact: "Exact domain"
        case .keyword: "Keyword"
        case .regex: "Regular expression"
        case .ip: "IP address or range"
        case .country: "Country"
        case .service: "Service list"
        case .invalid: "Not understood"
        }
    }

    var symbol: String {
        switch self {
        case .app: "app.dashed"
        case .domain: "globe"
        case .exact: "scope"
        case .keyword: "textformat.abc"
        case .regex: "chevron.left.forwardslash.chevron.right"
        case .ip: "number"
        case .country: "flag"
        case .service: "square.stack.3d.up"
        case .invalid: "questionmark.circle"
        }
    }
}

/// Picks, adds, renames and deletes rule profiles. Switching applies the other profile's rules at once,
/// so it waits until the draft is applied or reverted.
struct RuleProfileMenu: View {
    @Environment(AppModel.self) private var model
    // Read so the menu redraws when either changes.
    @AppStorage("ruleProfilesV2") private var storedProfiles = ""
    @AppStorage("activeRuleProfile") private var storedActive = ""
    @State private var renaming: UUID?
    @State private var name = ""
    @State private var deleting = false

    var body: some View {
        let _ = (storedProfiles, storedActive)
        let store = model.rules
        let profiles = Prefs.ruleProfiles
        let active = Prefs.activeRuleProfile
        Menu {
            Picker("Profile", selection: Binding { active } set: { id in if let id { store.switchProfile(to: id) } }) {
                ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New Profile") { store.addProfile(copying: []) }
            Button("Duplicate Profile") { store.addProfile(copying: store.saved) }
            Button("Rename Profile…") {
                renaming = active
                name = profiles.first { $0.id == active }?.name ?? ""
            }
            Button("Delete Profile…", role: .destructive) { deleting = true }
                .disabled(profiles.count < 2)
        } label: {
            Label(profiles.first { $0.id == active }?.name ?? "", systemImage: "square.stack.3d.up")
                .labelStyle(.titleAndIcon)
        }
        .disabled(store.hasChanges)
        .help(store.hasChanges ? "Apply or revert your changes to switch profiles" : "Rule profile")
        .alert("Rename Profile", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let renaming { store.renameProfile(renaming, to: name) } }
        }
        .confirmationDialog("Delete this profile and its rules?", isPresented: $deleting) {
            Button("Delete Profile", role: .destructive) { if let active { store.deleteProfile(active) } }
        }
    }
}

/// Review what a file holds before it is added to the draft, after the existing rules.
struct RuleImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: RuleImport
    let save: ([Rule]) -> Void

    var body: some View {
        let rules = model.resolvingVia(profile.rules)
        VStack(alignment: .leading, spacing: 16) {
            Text("Import \(profile.format.rawValue) rules").font(.title2.weight(.semibold))
            Text("\(rules.count) rules will be added after your rules, so yours keep their priority. Nothing changes until you apply.")
                .font(.callout).foregroundStyle(.secondary)
            List(rules) { rule in
                HStack(spacing: 10) {
                    Image(systemName: rule.action.symbol).foregroundStyle(rule.action.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.name).fontWeight(.medium)
                        Text(rule.itemSummary).font(.caption).foregroundStyle(.secondary)
                        if !rule.onlySummary.isEmpty {
                            Text("Only when: \(rule.onlySummary)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    if case .via(let via) = rule.action, model.viaName(via.target) == nil {
                        Label("No server named “\(via.name)”", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(rule.enabled ? rule.action.title(model) : String(localized: "Off"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
            if !profile.skipped.isEmpty {
                Label("Skipped, V2Mac has nothing like them: \(profile.skipped.joined(separator: ", ")).", systemImage: "exclamationmark.triangle")
                    .lineLimit(4)
                    .font(.callout).foregroundStyle(.orange)
            }
            if profile.blockQUIC {
                Label("Block QUIC (UDP 443) will be turned on.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Rules") { save(rules); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rules.isEmpty && !profile.blockQUIC)
            }
        }
        .padding(24)
        .frame(width: 580, height: 540)
    }
}

/// Tidy Up's suggestions, each with a checkbox; nothing changes without approval.
struct TidyUpSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let suggestions: [TidySuggestion]
    let apply: ([TidySuggestion]) -> Void
    @State private var chosen: Set<TidySuggestion> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tidy Up").font(.title2.weight(.semibold))
            if suggestions.isEmpty {
                ContentUnavailableView("Nothing to tidy", systemImage: "checkmark.circle", description: Text("Your rules have no duplicates or parts that never match."))
            } else {
                Text("Pick the changes to make. Only “Collapse spellings” can change what matches: it stops matching a program of the same name outside the app.")
                    .font(.callout).foregroundStyle(.secondary)
                List(suggestions) { suggestion in
                    Toggle(isOn: Binding { chosen.contains(suggestion) } set: { if $0 { chosen.insert(suggestion) } else { chosen.remove(suggestion) } }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(suggestion)).fontWeight(.medium)
                            Text(detail(suggestion)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button(chosen.count == suggestions.count ? "Select None" : "Select All") {
                    chosen = chosen.count == suggestions.count ? [] : Set(suggestions)
                }
                .disabled(suggestions.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make Changes") { apply(suggestions.filter(chosen.contains)); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 580, height: 520)
        .onAppear { chosen = Set(suggestions.filter { if case .collapseApps = $0.kind { false } else { true } }) }
    }

    private func name(_ id: UUID) -> String { model.rules.draft.first { $0.id == id }?.name ?? "" }

    private func title(_ s: TidySuggestion) -> String {
        switch s.kind {
        case .merge(let into, let from, let new): String(localized: "Merge “\(name(into))” and “\(name(from))” into “\(new)”")
        case .dropCovered(let rule, let items): String(localized: "Remove \(items.count) local entries from “\(name(rule))”")
        case .collapseApps(let rule, let items, _): String(localized: "Collapse \(items.count) spellings of one app in “\(name(rule))”")
        case .dropDuplicates(let rule, let items): String(localized: "Remove \(items.count) repeated entries from “\(name(rule))”")
        case .dropRule(let rule, let same): String(localized: "Delete “\(name(rule))”, the same as “\(name(same))”")
        }
    }

    private func detail(_ s: TidySuggestion) -> String {
        switch s.kind {
        case .merge: String(localized: "One has the apps, the other the hosts; one rule with both does the same.")
        case .dropCovered(_, let items): String(localized: "Local network already goes direct first: \(items.map(\.text).joined(separator: ", "))")
        case .collapseApps(_, let items, let into): String(localized: "\(items.joined(separator: ", ")) → \(into)")
        case .dropDuplicates(_, let items): items.map(\.text).joined(separator: ", ")
        case .dropRule: String(localized: "An earlier rule already matches the same traffic, so this one never does.")
        }
    }
}

/// Proxy, Direct or Block as the Connections window shows a route.
struct RuleList {
    let action: CustomRule.Action
    init(_ action: CustomRule.Action) { self.action = action }

    private var v2: Rule.Action {
        switch action {
        case .proxy: .proxy
        case .direct: .direct
        case .block: .block
        }
    }

    var symbol: String { v2.symbol }
    var tint: Color { v2.tint }
    var title: String {
        switch action {
        case .proxy: String(localized: "Proxy")
        case .direct: String(localized: "Direct")
        case .block: String(localized: "Block")
        }
    }
}

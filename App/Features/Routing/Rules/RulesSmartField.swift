import FoundationModels
import SwiftUI
import UniformTypeIdentifiers
import V2MacCore

// MARK: - Smart field

/// One field for every kind of item (spec 8.6). Typing shows installed apps, services, countries and the
/// text itself with its detected kind; ↑↓ and Return pick. Pasting many lines adds every one it can read.
struct SmartField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    let ruleID: UUID
    let browse: () -> Void
    @State private var text = ""
    @State private var suggestions: [Suggestion] = []
    @State private var highlighted = 0
    @State private var note: String?
    @State private var suggesting = false
    @FocusState private var focused: Bool

    struct Suggestion: Identifiable, Hashable {
        enum Section: Int { case typed, apps, services, countries }
        let section: Section
        let item: Rule.Item
        let title: String
        let detail: String
        var icon: String?
        var id: Rule.Item { item }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Add", text: $text, prompt: Text("App, site, address, country or service"))
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(suggestions.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) { text = ""; return .handled }
                    .onChange(of: text) { _, new in if new.contains(where: \.isNewline) { addPasted(new) } }
                Button("Browse…", action: browse)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, s in
                        Button { add([s.item]) } label: {
                            HStack(spacing: 8) {
                                if let path = s.icon {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: s.item.kind.symbol).frame(width: 16).foregroundStyle(.secondary)
                                }
                                Text(s.title).lineLimit(1)
                                Spacer()
                                Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(index == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if SystemLanguageModel.default.isAvailable, !text.isEmpty, !RuleMatchers.isIP(text) {
                        Button { suggestDomains() } label: {
                            Label(suggesting ? String(localized: "Asking Apple Intelligence…") : String(localized: "Suggest domains for “\(text)”"),
                                  systemImage: "apple.intelligence")
                                .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(suggesting)
                    }
                }
            }
        }
        .task(id: text) {
            note = nil
            try? await Task.sleep(for: .milliseconds(120))
            suggestions = await Self.suggestions(for: text, catalog: model.ruleCatalog)
            highlighted = 0
        }
    }

    private func submit() {
        if suggestions.indices.contains(highlighted) { add([suggestions[highlighted].item]) } else { addPasted(text) }
    }

    private func add(_ items: [Rule.Item]) {
        model.rules.add(items, to: ruleID, undo)
        text = ""
        suggestions = []
        focused = true
    }

    /// Every line in any form the importers read; the skipped ones are named.
    private func addPasted(_ pasted: String) {
        let (items, skipped) = Rule.Item.parse(pasted)
        if !items.isEmpty { add(items) }
        note = skipped.isEmpty ? nil : String(localized: "Not understood: \(skipped.joined(separator: ", "))")
        if items.isEmpty && skipped.isEmpty { text = "" }
    }

    static func suggestions(for raw: String, catalog: RuleCatalog) async -> [Suggestion] {
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !query.contains(where: \.isNewline) else { return [] }
        var out: [Suggestion] = []
        // The text itself, as the kind it reads as.
        if let item = Rule.Item.parse(query).items.first {
            out.append(Suggestion(section: .typed, item: item, title: item.text, detail: String(localized: "Add as \(String(localized: item.kind.titleResource))")))
        }
        for app in catalog.apps where app.name.localizedCaseInsensitiveContains(query) || app.bundleID.localizedCaseInsensitiveContains(query) {
            out.append(Suggestion(section: .apps, item: .app(app.bundleID), title: (app.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
                                  detail: app.bundleID, icon: app.path))
            if out.count > 6 { break }
        }
        for country in catalog.geo.countries where country.name.localizedStandardContains(query)
            || country.englishName.localizedStandardContains(query) || country.code.caseInsensitiveCompare(query) == .orderedSame {
            out.append(Suggestion(section: .countries, item: .country(country.code), title: "\(country.flag) \(country.name)", detail: country.code.uppercased()))
            if out.filter({ $0.section == .countries }).count >= 3 { break }
        }
        // Lists by name, then lists that contain the text, with their sizes.
        let lists = catalog.lists
        let services = await Task.detached {
            let lower = query.lowercased()
            var byName: [(String, Int)] = [], byContent: [(String, Int)] = []
            for (key, entries) in lists.sites {
                let name = String(key.drop { $0 != ":" }.dropFirst())
                if name.contains(lower) { byName.append((name, entries.count)) }
                else if lower.count >= 3, entries.contains(where: { $0.value.contains(lower) }) { byContent.append((name, entries.count)) }
            }
            return (byName.sorted { $0.0.count < $1.0.count } + byContent.sorted { $0.1 < $1.1 }).prefix(6)
        }.value
        for (name, count) in services where catalog.geo.lists.contains("geosite:\(name)") {
            out.append(Suggestion(section: .services, item: .host("geosite:\(name)"), title: "geosite:\(name)", detail: String(localized: "\(count) entries")))
        }
        for list in catalog.geo.lists where list.hasPrefix("geoip:") && list.localizedCaseInsensitiveContains(query) {
            out.append(Suggestion(section: .services, item: .host(list), title: list, detail: String(localized: "addresses")))
        }
        return out.sorted { $0.section.rawValue < $1.section.rawValue }
    }

    /// On-device Apple Intelligence names the domains a service uses.
    private func suggestDomains() {
        let request = text.trimmingCharacters(in: .whitespaces)
        suggesting = true
        Task {
            defer { suggesting = false }
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let answer = try await session.respond(to: request, generating: SuggestedDomains.self).content
                let items = answer.domains.compactMap { Rule.Item.item($0.lowercased(), as: .domain) }
                if items.isEmpty { note = String(localized: "No domains were suggested. Try naming the service differently.") } else { add(items) }
            } catch {
                note = error.localizedDescription
            }
        }
    }

    /// Tried against the on-device model: without the examples it gives only the main domain,
    /// without "each domain once" it can repeat one until the count runs out.
    private static let instructions = """
        You list the domain names that internet services use, so a proxy app can route them. \
        For each service, give its main domain and the other domains it loads content from. \
        Example: for "Netflix" answer netflix.com, nflxvideo.net, nflximg.net, nflxext.com, nflxso.net. \
        For "YouTube": youtube.com, googlevideo.com, ytimg.com, youtu.be, ggpht.com. \
        Give bare domains only, without www, paths or IP addresses. \
        List each domain once. Never guess a domain you do not know.
        """
}

@Generable
struct SuggestedDomains {
    @Guide(description: "Every domain the services use: their main site, video and image servers (CDNs), APIs and short links", .count(1...20))
    var domains: [String]
}

extension Rule.Item.Kind {
    /// The kind's name as a resource, for building a sentence around it.
    var titleResource: LocalizedStringResource {
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
}

// MARK: - Browse

/// The visual pickers: an app checklist, service tiles and the country map.
struct BrowseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let add: ([Rule.Item]) -> Void
    @State private var pane = Pane.apps
    @State private var apps: Set<String> = []
    @State private var services: Set<String> = []
    @State private var countries: Set<String> = []
    @State private var countryOptions = CountryRuleOptions()
    @State private var search = ""

    enum Pane: String, CaseIterable, Identifiable {
        case apps = "Apps", services = "Services", countries = "Countries"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Browse", selection: $pane) {
                ForEach(Pane.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            switch pane {
            case .apps: appList
            case .services: ServicePicker(catalog: model.ruleCatalog.geo, selected: $services)
            case .countries: CountryPicker(catalog: model.ruleCatalog.geo, selected: $countries, options: $countryOptions)
            }
            Divider()
            HStack {
                Text("\(apps.count + services.count + countries.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    // A country with every option on is one country token; otherwise its parts.
                    let countryItems: [Rule.Item] = countries.sorted().flatMap { code -> [Rule.Item] in
                        countryOptions == CountryRuleOptions() ? [.country(code)]
                            : countryOptions.rules(for: code, siteTags: model.ruleCatalog.geo.siteTags).map(Rule.Item.host)
                    }
                    add(apps.sorted().map(Rule.Item.app) + services.sorted().map(Rule.Item.host) + countryItems)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 860, height: 580)
    }

    private var appList: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "Search \(model.ruleCatalog.apps.count) apps", text: $search).padding(10)
            List(model.ruleCatalog.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.path) { app in
                Toggle(isOn: Binding { apps.contains(app.bundleID) } set: { on in if on { apps.insert(app.bundleID) } else { apps.remove(app.bundleID) } }) {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 18, height: 18)
                        Text((app.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))
                        Spacer()
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Search answer

/// "api.github.com → Proxy, by Developer services (#8), matched `*github*`" (spec 8.6), worked out with
/// the draft, the built-ins, the geo lists' contents and the mode's default.
struct SearchAnswer: Equatable {
    var query: String
    var destination: String
    var by: String
    var matched: String?
    var rule: UUID?
    var builtIn: RulesStore.BuiltIn?

    @MainActor static func find(_ text: String, model: AppModel) async -> SearchAnswer? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let catalog = model.ruleCatalog
        let query: RouteQuery
        if RuleMatchers.isIP(text) {
            query = RouteQuery(ips: [text])
        } else if let host = URL(string: text).flatMap(\.host) ?? (text.contains(".") && !text.contains(" ") ? text : nil),
                  !host.contains(" ") {
            query = RouteQuery(host: host, ips: await KillSwitch.addresses(of: [host]))
        } else if let app = catalog.apps.first(where: { $0.name.localizedCaseInsensitiveContains(text) }) {
            let name = (app.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            query = RouteQuery(process: app.path + "/Contents/MacOS/" + name)
        } else {
            return nil
        }
        var custom = CustomRules(rules: model.rules.draft, installedApps: catalog.apps, blockQUIC: UserDefaults.standard.bool(forKey: "blockQUIC"),
                                 unmatchedRoute: CustomRule.Action(rawValue: UserDefaults.standard.string(forKey: "unmatchedRoute") ?? ""),
                                 siteTags: catalog.geo.siteTags)
        let targets = Set(custom.rules.compactMap { r -> Rule.Via.Target? in if case .via(let v) = r.action { v.target } else { nil } })
        custom.viaServers = model.connection.viaServers(targets)
        let plan = model.connection.routingPlan
        let answer = RuleTester.route(query, plan: plan, custom: custom, geo: catalog.lists)
        var out = SearchAnswer(query: text, destination: "", by: "", matched: answer?.matched)
        if let id = answer?.ruleTag.flatMap(RuleTag.ruleID), let index = custom.rules.firstIndex(where: { $0.id == id }) {
            let rule = custom.rules[index]
            out.destination = rule.action.title(model)
            out.by = String(localized: "by \(rule.name) (#\(index + 1))")
            out.rule = id
            return out
        }
        switch answer?.ruleTag {
        case RuleTag.localNames?, RuleTag.privateIPs?: out.builtIn = .localNetwork; out.by = String(localized: "by Local network")
        case RuleTag.quic?: out.builtIn = .blockQUIC; out.by = String(localized: "by Block QUIC")
        case RuleTag.unmatched?: out.builtIn = .everythingElse; out.by = String(localized: "by Everything else")
        default: out.builtIn = answer == nil ? .everythingElse : .mode; out.by = String(localized: "by the routing mode")
        }
        out.destination = switch answer?.outbound {
        case ConfigBuilder.directTag?: String(localized: "Direct")
        case ConfigBuilder.blockTag?: String(localized: "Block")
        default: String(localized: "Proxy")
        }
        return out
    }
}

struct SearchAnswerRow: View {
    let answer: SearchAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(answer.query) → \(answer.destination)").fontWeight(.medium).lineLimit(1)
            Text([answer.by, answer.matched.map { String(localized: "matched \($0)") }].compactMap { $0 }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

// MARK: - Discovered

extension ConnectionWatcher {
    /// What a Discovered row adds to a rule.
    struct Uncovered: Identifiable, Hashable {
        let id: String
        let item: Rule.Item
        let title: String
        let count: Int
        let last: Date
        /// A host's registered domain, offered instead of the host.
        var domain: String?
    }

    /// Apps and hosts seen while a window was open that no rule and no built-in covers.
    func uncovered(by rules: [Rule], catalog: RuleCatalog, ignored: Set<String> = Prefs.ignoredDiscoveries) -> [Uncovered] {
        let installed = catalog.apps
        let custom = CustomRules(rules: rules.filter(\.enabled), installedApps: installed, siteTags: catalog.geo.siteTags)
        // Global mode has no rules of its own, so any answer is a user rule or a built-in.
        func covered(_ q: RouteQuery) -> Bool {
            RuleTester.route(q, plan: .global, custom: custom, geo: catalog.lists) != nil
        }
        var out: [Uncovered] = []
        for app in apps.values where !ignored.contains(app.id) {
            let process = app.id.hasSuffix(".app") ? app.id + "/Contents/MacOS/x" : app.id
            guard !covered(RouteQuery(process: process)) else { continue }
            let entry = installed.first { $0.path == app.id }?.bundleID ?? app.id
            out.append(Uncovered(id: app.id, item: .app(entry), title: (app.id as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
                                 count: app.count, last: app.last))
        }
        for host in hosts.values where !ignored.contains(host.id) {
            let query = RuleMatchers.isIP(host.id) ? RouteQuery(ips: [host.id]) : RouteQuery(host: host.id)
            guard !covered(query) else { continue }
            let item: Rule.Item = RuleMatchers.isIP(host.id) ? .host(host.id) : .host("full:" + host.id)
            out.append(Uncovered(id: host.id, item: item, title: host.id, count: host.count, last: host.last,
                                 domain: EntryGroups.registeredDomain(ofHost: host.id).flatMap { $0 == host.id ? nil : $0 }))
        }
        return out.sorted { $0.count > $1.count }
    }
}

/// Apps and hosts no rule covers, to add to a rule (spec 8.6). Recorded only while this window or the
/// Connections window is open.
struct DiscoveredView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    @State private var selection: Set<String> = []

    var body: some View {
        let rows = model.connection.watcher.uncovered(by: model.rules.draft, catalog: model.ruleCatalog)
        let chosen = rows.filter { selection.contains($0.id) }
        VStack(spacing: 0) {
            List(rows, selection: $selection) { row in
                HStack(spacing: 8) {
                    if case .app(let entry) = row.item, let path = model.ruleCatalog.apps.app(for: entry)?.path {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: row.item.kind.symbol).frame(width: 18).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).lineLimit(1)
                        Text("\(row.count) connections, last \(row.last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    AddToMenu(entries: [row], useDomain: true)
                }
                .draggable(RuleItemsTransfer(items: [row.domain.flatMap { Rule.Item.item($0, as: .domain) } ?? row.item]))
            }
            .listStyle(.inset)
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("Nothing new", systemImage: "binoculars",
                                           description: Text("Apps and sites that no rule covers appear here while this window is open and V2Mac is connected."))
                }
            }
            if !chosen.isEmpty {
                Divider()
                HStack {
                    Text("\(chosen.count) selected").foregroundStyle(.secondary)
                    Spacer()
                    AddToMenu(entries: chosen, useDomain: true)
                }
                .padding(10)
            }
        }
        .navigationTitle("Discovered")
    }
}

/// "Add to ▾": rules, most recently used first; New Rule…; Ignore.
struct AddToMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    let entries: [ConnectionWatcher.Uncovered]
    /// A host is added as its registered domain and subdomains.
    var useDomain = false

    var body: some View {
        let store = model.rules
        let items = entries.map { entry in useDomain ? entry.domain.flatMap { Rule.Item.item($0, as: .domain) } ?? entry.item : entry.item }
        let recent = store.recentTargets.compactMap { id in store.draft.first { $0.id == id } }
        Menu("Add to") {
            ForEach(recent + store.draft.filter { r in !recent.contains { $0.id == r.id } }) { rule in
                Button(rule.name) { store.add(items, to: rule.id, undo) }
            }
            Divider()
            Button("New Rule…") {
                store.add(Rule(name: entries.count == 1 ? entries[0].title : String(localized: "New rule"), action: .proxy, items: items), undo)
            }
            if useDomain, entries.count == 1, entries[0].domain != nil {
                Button("Add Only “\(entries[0].title)”…") {
                    store.add(Rule(name: entries[0].title, action: .proxy, items: [entries[0].item]), undo)
                }
            }
            Divider()
            Button("Ignore") { Prefs.ignoredDiscoveries.formUnion(entries.map(\.id)) }
        }
        .fixedSize()
        .controlSize(.small)
    }
}

/// Items dragged from Discovered or Connections onto a rule in the sidebar.
struct RuleItemsTransfer: Codable, Transferable {
    let items: [Rule.Item]
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

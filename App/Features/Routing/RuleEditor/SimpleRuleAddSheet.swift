import FoundationModels
import SwiftUI
import V2MacCore

/// Adds installed apps or typed domains through the same moves as the simple editor's rows.
struct SimpleRuleAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RuleEntry.Kind
    @State private var apps: [InstalledApp] = []
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var hosts = ""
    @State private var action = CustomRule.Action.proxy
    @State private var isLoading = true
    @State private var request = ""
    @State private var isSuggesting = false
    @State private var suggestionError: String?
    let save: ([RuleEntry], CustomRule.Action) -> Void

    init(initialKind: RuleEntry.Kind, save: @escaping ([RuleEntry], CustomRule.Action) -> Void) {
        _kind = State(initialValue: initialKind)
        self.save = save
    }

    private var hostLines: [String] {
        hosts.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var invalidHosts: [String] { hostLines.filter { !Self.isDomain($0) } }

    private static func isDomain(_ line: String) -> Bool {
        let parsed = RuleMatchers(parsing: line)
        return parsed.invalid.isEmpty && parsed.domains.count == 1 && parsed.ips.isEmpty && !SeenGroup.isTechnical(RuleEntry(.host, line))
    }

    private var entries: [RuleEntry] {
        let values = kind == .app ? selected.sorted() : Array(Set(hostLines)).sorted()
        return values.map { RuleEntry(kind, $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add to your library").font(.title2.weight(.semibold))
                Text("Pick apps or enter hosts, then choose how they connect.")
                    .foregroundStyle(.secondary)
            }
            Picker("Add", selection: $kind) {
                Text("Apps").tag(RuleEntry.Kind.app)
                Text("Hosts").tag(RuleEntry.Kind.host)
            }
            .pickerStyle(.segmented)
            if kind == .app {
                SearchField(prompt: "Search installed apps", text: $search)
                List {
                    ForEach(apps.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.bundleID.localizedStandardContains(search) }, id: \.path) { app in
                        Toggle(isOn: Binding(
                            get: { selected.contains(app.path) },
                            set: { on in if on { selected.insert(app.path) } else { selected.remove(app.path) } }
                        )) {
                            HStack(spacing: 10) {
                                EntryIcon(entry: RuleEntry(.app, app.path))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SeenGroup.displayName(RuleEntry(.app, app.path)))
                                    Text(app.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if isLoading { ProgressView("Loading apps…") }
                    else if apps.isEmpty { ContentUnavailableView("No installed apps found", systemImage: "square.grid.2x2") }
                }
                Text("App rules apply to proxy connections. TUN uses host rules.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if SystemLanguageModel.default.isAvailable { suggestionField }
                Text("One domain per line. Use *.example.com to include subdomains.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("example.com\n*.example.org", text: $hosts, axis: .vertical)
                    .lineLimit(8...12)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Hosts, one per line")
                if !invalidHosts.isEmpty {
                    Label("Enter domain names here. Use Advanced for IP addresses and other matchers.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            Divider()
            Picker("Route", selection: $action) {
                ForEach(CustomRule.Action.allCases, id: \.self) { action in
                    Label(RuleList(action).title, systemImage: RuleList(action).symbol).tag(action)
                }
            }
            .pickerStyle(.segmented)
            Text(RuleList(action).summary).font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("\(entries.count) selected").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { save(entries, action); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(entries.isEmpty || (kind == .host && !invalidHosts.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 520, height: 600)
        .task {
            apps = await InstalledApps.all().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            isLoading = false
        }
    }

    // MARK: Suggestions (Apple Intelligence, on this Mac)

    private var suggestionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Describe the sites, such as “Netflix and YouTube”", text: $request)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(suggest)
                Button("Suggest Domains", systemImage: "sparkles", action: suggest)
                    .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty || isSuggesting)
            }
            if isSuggesting {
                ProgressView().controlSize(.small)
            } else if let suggestionError {
                Text(suggestionError).font(.caption).foregroundStyle(.red)
            } else {
                Text("Apple Intelligence suggests domains on this Mac. Check them before adding: the list can be wrong or incomplete.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private func suggest() {
        let request = request.trimmingCharacters(in: .whitespaces)
        guard !request.isEmpty, !isSuggesting else { return }
        isSuggesting = true
        suggestionError = nil
        Task {
            defer { isSuggesting = false }
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let answer = try await session.respond(to: request, generating: SuggestedDomains.self).content
                let found = answer.domains.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter(Self.isDomain)
                guard !found.isEmpty else { return suggestionError = String(localized: "No domains were suggested. Try naming the service differently.") }
                var lines = hostLines
                for domain in found where !lines.contains(domain) { lines.append(domain) }
                hosts = lines.joined(separator: "\n")
            } catch {
                suggestionError = error.localizedDescription
            }
        }
    }
}

@Generable
struct SuggestedDomains {
    @Guide(description: "Every domain the services use: their main site, video and image servers (CDNs), APIs and short links", .count(1...20))
    var domains: [String]
}

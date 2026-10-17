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
    let save: ([RuleEntry], CustomRule.Action) -> Void

    init(initialKind: RuleEntry.Kind, save: @escaping ([RuleEntry], CustomRule.Action) -> Void) {
        _kind = State(initialValue: initialKind)
        self.save = save
    }

    private var hostLines: [String] {
        hosts.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var invalidHosts: [String] {
        hostLines.filter {
            let parsed = RuleMatchers(parsing: $0)
            return !parsed.invalid.isEmpty || parsed.domains.count != 1 || !parsed.ips.isEmpty || SeenGroup.isTechnical(RuleEntry(.host, $0))
        }
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
        .frame(width: 520, height: 570)
        .task {
            apps = await InstalledApps.all().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            isLoading = false
        }
    }
}

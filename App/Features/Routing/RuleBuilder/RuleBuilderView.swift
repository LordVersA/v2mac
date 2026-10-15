import SwiftUI
import V2MacCore

/// The three lists of spec 8.6, stored in `UserDefaults` under `key`.
enum RuleList: String, CaseIterable, Identifiable {
    case proxy = "Proxy", direct = "Direct", block = "Block"
    var id: Self { self }
    var key: String { "customRules\(rawValue)" }
    var saved: String { UserDefaults.standard.string(forKey: key) ?? "" }

    var symbol: String {
        switch self {
        case .proxy: "lock.shield.fill"
        case .direct: "arrow.right.circle.fill"
        case .block: "nosign"
        }
    }

    var tint: Color {
        switch self {
        case .proxy: .blue
        case .direct: .green
        case .block: .red
        }
    }

    var summary: String {
        switch self {
        case .proxy: "Send through the server, whatever the mode says."
        case .direct: "Connect without the proxy, from your own network."
        case .block: "Refuse the connection, for ads, trackers or anything unwanted."
        }
    }
}

/// Spec 8.6: a step-by-step way to write custom rules, from countries on a map,
/// known services and site lists, or typed domains and addresses.
struct RuleBuilderView: View {
    enum Step: Int, CaseIterable {
        case action, targets, review
        var title: String {
            switch self {
            case .action: "Action"
            case .targets: "Choose"
            case .review: "Review"
            }
        }
    }

    enum Source: String, CaseIterable, Identifiable {
        case countries = "Countries", services = "Services", manual = "Domains & IPs"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .countries: "globe.europe.africa.fill"
            case .services: "square.grid.2x2.fill"
            case .manual: "character.cursor.ibeam"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var catalog = GeoCatalog()
    @State private var step = Step.action
    @State private var list = RuleList.direct
    @State private var source = Source.countries
    @State private var countries: Set<String> = []
    @State private var countryOptions = CountryRuleOptions()
    @State private var services: Set<String> = []
    @State private var manual = ""
    @State private var replace = false

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(step: step)
                .padding(.vertical, 14)
            Divider()
            Group {
                switch step {
                case .action: actionStep
                case .targets: targetsStep
                case .review: reviewStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            catalog = await GeoCatalog.load()
            #if DEBUG
            debugStep()
            #endif
        }
    }

    #if DEBUG
    /// `-debugRuleBuilder <step>[:<source>]` (`targets:countries`, `review`…) jumps to that step
    /// with a few made-up picks, so `-debugSnapshot` can show it.
    private func debugStep() {
        guard let value = UserDefaults.standard.string(forKey: "debugRuleBuilder") else { return }
        let parts = value.split(separator: ":").map(String.init)
        step = ["action": .action, "targets": .targets, "review": .review][parts[0]] ?? .action
        if parts.count > 1, let picked = Source.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(parts[1]) }) { source = picked }
        countries = ["ir", "de", "jp"]
        services = catalog.available(["geosite:apple", "geosite:microsoft"])
        manual = "example.com\n10.0.0.0/8\nDOMAIN-SUFFIX,clash.example,DIRECT\nnot a rule!"
    }
    #endif

    // MARK: Step 1

    private var actionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("What should happen to the traffic you pick?")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 14) {
                    ForEach(RuleList.allCases) { option in
                        ActionCard(list: option, isSelected: list == option) { list = option }
                    }
                }
                if !quickStarts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or start from a common setup")
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                            ForEach(quickStarts) { start in
                                Button { apply(start) } label: {
                                    Label(start.title, systemImage: start.symbol)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    struct QuickStart: Identifiable {
        let title: String
        let symbol: String
        let list: RuleList
        var countries: Set<String> = []
        var services: Set<String> = []
        var id: String { title }
    }

    private var quickStarts: [QuickStart] {
        guard catalog.isLoaded else { return [] }
        var out: [QuickStart] = []
        if let code = Locale.current.region?.identifier.lowercased(), let home = catalog.country(code) {
            out.append(QuickStart(title: "Keep \(home.flag) \(home.name) direct", symbol: "house.fill", list: .direct, countries: [code]))
        }
        out.append(QuickStart(title: "Block ads and trackers", symbol: "eye.slash.fill", list: .block, services: catalog.available(["geosite:category-ads-all"])))
        out.append(QuickStart(title: "AI services through the proxy", symbol: "sparkles", list: .proxy,
                              services: catalog.available(["geosite:category-ai-!cn", "geosite:openai", "geosite:anthropic"])))
        out.append(QuickStart(title: "Telegram through the proxy", symbol: "paperplane.fill", list: .proxy,
                              services: catalog.available(["geosite:telegram", "geoip:telegram"])))
        out.append(QuickStart(title: "Streaming through the proxy", symbol: "play.tv.fill", list: .proxy,
                              services: catalog.available(["geosite:youtube", "geosite:netflix", "geoip:netflix", "geosite:spotify"])))
        return out.filter { !$0.countries.isEmpty || !$0.services.isEmpty }
    }

    private func apply(_ start: QuickStart) {
        list = start.list
        countries = start.countries
        services = start.services
        manual = ""
        step = .review
    }

    // MARK: Step 2

    private var targetsStep: some View {
        VStack(spacing: 0) {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { source in
                    Label("\(source.rawValue)\(count(source).map { " (\($0))" } ?? "")", systemImage: source.symbol).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
            .padding(12)
            Divider()
            if !catalog.isLoaded {
                ProgressView("Reading the rule files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch source {
                case .countries: CountryPicker(catalog: catalog, selected: $countries, options: $countryOptions)
                case .services: ServicePicker(catalog: catalog, selected: $services)
                case .manual: ManualEntry(text: $manual)
                }
            }
        }
    }

    private func count(_ source: Source) -> Int? {
        let n = switch source {
        case .countries: countries.count
        case .services: services.count
        case .manual: RuleMatchers(parsing: manual).domains.count + RuleMatchers(parsing: manual).ips.count
        }
        return n == 0 ? nil : n
    }

    // MARK: Step 3

    private var generated: [String] {
        var out: [String] = []
        for country in catalog.countries where countries.contains(country.code) {
            out += countryOptions.rules(for: country.code, siteTags: catalog.siteTags)
        }
        out += services.sorted()
        let typed = RuleMatchers(parsing: manual)
        out += typed.domains + typed.ips
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private var existing: Set<String> {
        let parsed = RuleMatchers(parsing: list.saved)
        return Set(parsed.domains + parsed.ips)
    }

    /// The rules this run adds: in replace mode all of them, otherwise only the new ones.
    private var toWrite: [String] {
        replace ? generated : generated.filter { !existing.contains($0) }
    }

    private var reviewStep: some View {
        let rules = generated
        let already = replace ? [] : rules.filter(existing.contains)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text("\(toWrite.count) \(toWrite.count == 1 ? "rule" : "rules") for the \(list.rawValue) list")
                        .font(.title2.weight(.semibold))
                } icon: {
                    Image(systemName: list.symbol).foregroundStyle(list.tint)
                }
                Spacer()
                Picker("", selection: $replace) {
                    Text("Add to the list").tag(false)
                    Text("Replace the list").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if replace, !list.saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("The \(list.rawValue) list's current rules will be removed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if rules.isEmpty {
                ContentUnavailableView("Nothing chosen", systemImage: "tray",
                                       description: Text("Go back and pick countries, services or domains."))
            } else {
                List(rules, id: \.self) { rule in
                    RuleRow(rule: rule, isDuplicate: already.contains(rule))
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
            }
            Text("Rules are checked before the routing mode: Block first, then Proxy, then Direct. The core restarts to use them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func save() {
        let header = "# Rule Builder, \(Date.now.formatted(date: .abbreviated, time: .omitted))"
        let block = ([header] + toWrite).joined(separator: "\n")
        let current = list.saved
        let text: String
        if replace || current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = block
        } else {
            text = current + (current.hasSuffix("\n") ? "\n" : "\n\n") + block
        }
        UserDefaults.standard.set(text, forKey: list.key)
        model.connection.reconnectIfRunning()
        dismissWindow(id: RuleBuilderView.windowID)
    }

    static let windowID = WindowRequest.ruleBuilderID

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismissWindow(id: Self.windowID) }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if step == .targets, !generated.isEmpty {
                Text("\(generated.count) \(generated.count == 1 ? "rule" : "rules") so far")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if step != .action {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .action }
            }
            if step == .review {
                Button("Add Rules") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(toWrite.isEmpty && !replace)
            } else {
                Button("Continue") { step = Step(rawValue: step.rawValue + 1) ?? .review }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .targets && generated.isEmpty)
            }
        }
        .controlSize(.large)
        .padding(14)
    }
}

// MARK: - Pieces

private struct StepIndicator: View {
    let step: RuleBuilderView.Step

    var body: some View {
        HStack(spacing: 10) {
            ForEach(RuleBuilderView.Step.allCases, id: \.self) { item in
                if item != .action {
                    Capsule().fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 48, height: 2)
                }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        if item.rawValue < step.rawValue {
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                        } else {
                            Text("\(item.rawValue + 1)").font(.caption.bold())
                                .foregroundStyle(item == step ? .white : .secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(item.title)
                        .fontWeight(item == step ? .semibold : .regular)
                        .foregroundStyle(item == step ? .primary : .secondary)
                }
            }
        }
    }
}

private struct ActionCard: View {
    let list: RuleList
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: list.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(list.tint)
                Text(list.rawValue).font(.title3.weight(.semibold))
                Text(list.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .padding(16)
            .background(isSelected ? list.tint.opacity(0.12) : Color.secondary.opacity(0.06), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? list.tint : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RuleRow: View {
    let rule: String
    let isDuplicate: Bool

    private var kind: (symbol: String, text: String) {
        switch rule.split(separator: ":").first.map(String.init) {
        case "geoip": ("map.fill", "IP ranges")
        case "geosite": ("list.bullet.rectangle.fill", "Site list")
        case "domain": ("globe", "Domain and subdomains")
        case "full": ("globe", "Exact domain")
        case "keyword": ("text.magnifyingglass", "Domain keyword")
        case "regexp": ("asterisk", "Pattern")
        default: ("number", "Address")
        }
    }

    var body: some View {
        HStack {
            Image(systemName: kind.symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(rule).font(.body.monospaced())
            Spacer()
            if isDuplicate {
                Text("Already in the list").foregroundStyle(.tertiary)
            } else {
                Text(kind.text).foregroundStyle(.secondary)
            }
        }
        .opacity(isDuplicate ? 0.6 : 1)
    }
}

private struct ManualEntry: View {
    @Binding var text: String

    var body: some View {
        let parsed = RuleMatchers(parsing: text)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
                HStack {
                    Text("\(parsed.domains.count) domains, \(parsed.ips.count) IP rules").foregroundStyle(.secondary)
                    if !parsed.invalid.isEmpty {
                        Label("Skipped: \(parsed.invalid.prefix(3).joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .font(.callout)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Accepted formats").font(.headline)
                    ForEach(Self.examples, id: \.0) { example in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(example.0).font(.callout.monospaced())
                            Text(example.1).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 270)
        }
    }

    static let examples: [(String, String)] = [
        ("example.com", "The domain and all its subdomains"),
        ("*.example.com", "Same, written as a wildcard"),
        ("full:www.example.com", "Only this exact name"),
        ("keyword:shop", "Any name containing the word"),
        ("regexp:^ads\\d+\\.", "A regular expression"),
        ("1.2.3.4  ·  10.0.0.0/8", "An address or a range, IPv4 or IPv6"),
        ("geosite:google", "A site list from geosite.dat"),
        ("geoip:de", "A country's addresses"),
        ("DOMAIN-SUFFIX,example.com", "Clash rules, paste them as they are"),
        ("0.0.0.0 ads.example.com", "Lines from a hosts file"),
        ("||ads.example.com^", "Adblock domain lines"),
    ]
}

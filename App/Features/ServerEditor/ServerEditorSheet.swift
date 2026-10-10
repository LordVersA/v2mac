import SwiftUI
import V2MacCore

/// What the server editor is working on (spec 12.7).
struct ServerEditorRequest: Identifiable {
    enum Target: Equatable {
        case new
        case edit(UUID)
        /// A subscription's server: the edited version is saved next to the pasted configs.
        case copy(UUID)
    }

    let id = UUID()
    let target: Target
}

/// Adds a server by hand, or changes one, field by field (spec 12.7).
struct ServerEditorSheet: View {
    let request: ServerEditorRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ServerDraft
    /// Set for what the form has no fields for: a full Xray config, or an outbound of another
    /// protocol. Those are edited as JSON.
    @State private var json: String?
    @State private var jsonName: String
    @State private var problems: [String] = []

    init(request: ServerEditorRequest, profile: Profile?) {
        self.request = request
        var draft = ServerDraft()
        var json: String?
        if let profile, let config = profile.config {
            if profile.kind == .outbound, let read = ServerDraft(outbound: config, name: profile.name) {
                draft = read
            } else {
                json = (try? config.data(pretty: true)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
        }
        #if DEBUG
        // `-debugEditProtocol <protocol>`: the form a new server of that protocol starts with.
        if profile == nil, let proto = UserDefaults.standard.string(forKey: "debugEditProtocol").flatMap(ServerDraft.Proto.init) {
            draft = ServerDraft(proto: proto)
        }
        #endif
        _draft = State(initialValue: draft)
        _json = State(initialValue: json)
        _jsonName = State(initialValue: profile?.name ?? "")
    }

    /// `-debugEditorHeight <points>` makes room for the whole form in a snapshot.
    private static var formHeight: CGFloat {
        #if DEBUG
        let override = UserDefaults.standard.integer(forKey: "debugEditorHeight")
        if override > 0 { return CGFloat(override) }
        #endif
        return 470
    }

    private var title: LocalizedStringKey {
        switch request.target {
        case .new: "New Server"
        case .edit: "Edit Server"
        case .copy: "Edit a Copy"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if case .copy = request.target {
                    Text("A subscription replaces its servers on every update, so the edited copy is saved in Custom Configs.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], 20)

            Form {
                if json != nil { jsonSections } else { formSections }
            }
            .formStyle(.grouped)
            .frame(height: Self.formHeight)

            VStack(alignment: .leading, spacing: 12) {
                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .transition(.opacity)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                }
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 8)
        }
        .frame(width: 520)
        .animation(.snappy, value: problems)
    }

    private func save() {
        do {
            let parsed: ParsedProfile
            if let json {
                guard let only = try SubscriptionParser.parse(text: json).profiles.first else {
                    throw DraftError(["This is not an Xray config or outbound that V2Mac can run."])
                }
                var named = only
                let name = jsonName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { named.name = name }
                parsed = named
            } else {
                parsed = try draft.profile()
            }
            model.saveServer(parsed, target: request.target)
            dismiss()
        } catch let error as DraftError {
            problems = error.problems
        } catch {
            problems = [error.localizedDescription]
        }
    }

    // MARK: JSON

    @ViewBuilder
    private var jsonSections: some View {
        Section {
            TextField("Name", text: $jsonName)
        }
        Section("Xray Config") {
            // A text field rather than a text editor: it never swaps in smart quotes, which break JSON.
            TextField("Config", text: Binding(get: { json ?? "" }, set: { json = $0 }), axis: .vertical)
                .labelsHidden()
                .lineLimit(18...18)
                .font(.callout.monospaced())
        }
    }

    // MARK: Form

    @ViewBuilder
    private var formSections: some View {
        Section("Server") {
            TextField("Name", text: $draft.name, prompt: Text("(address and port)"))
            Picker("Protocol", selection: $draft.proto) {
                ForEach(ServerDraft.Proto.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: draft.proto) { old, _ in draft.protocolChanged(from: old) }
            TextField("Address", text: $draft.address, prompt: Text("server.example.com"))
            TextField("Port", text: $draft.port)
        }

        switch draft.proto {
        case .vless:
            Section("VLESS") {
                userID
                picker("Flow", $draft.flow, ServerDraft.flows, empty: "None")
                TextField("Encryption", text: $draft.encryption, prompt: Text("none"))
            }
        case .vmess:
            Section("VMess") {
                userID
                picker("Encryption", $draft.vmessSecurity, ServerDraft.vmessSecurities)
            }
        case .trojan:
            Section("Trojan") { secret("Password", $draft.password) }
        case .shadowsocks:
            Section("Shadowsocks") {
                picker("Method", $draft.method, ServerDraft.shadowsocksMethods)
                secret("Password", $draft.password)
            }
        case .hysteria:
            hysteriaSections
        case .wireguard:
            wireguardSections
        case .socks, .http:
            Section(draft.proto.title) {
                TextField("Username", text: $draft.username, prompt: Text("(none)"))
                secret("Password", $draft.password, prompt: "(none)")
                if draft.proto == .http {
                    Toggle("Connect with TLS (HTTPS)", isOn: Binding(
                        get: { draft.security == "tls" }, set: { draft.security = $0 ? "tls" : "none" }
                    ))
                    if draft.security == "tls" { TextField("SNI", text: $draft.sni, prompt: Text("(server address)")) }
                }
            }
        }

        if draft.proto.hasStream {
            transportSection
            securitySection
            muxSection
        }
    }

    private var userID: some View {
        LabeledContent("User ID") {
            HStack(spacing: 6) {
                TextField("User ID", text: $draft.id, prompt: Text("UUID"))
                    .labelsHidden()
                    .font(.callout.monospaced())
                Button("Generate", systemImage: "dice") { draft.id = UUID().uuidString.lowercased() }
                    .labelStyle(.iconOnly)
                    .help("Make a new random UUID")
            }
        }
    }

    private func secret(_ title: LocalizedStringKey, _ text: Binding<String>, prompt: String = "") -> some View {
        TextField(title, text: text, prompt: Text(prompt))
    }

    /// A menu of the usual values, plus the server's own value when it is none of them.
    private func picker(_ title: LocalizedStringKey, _ selection: Binding<String>, _ options: [String], empty: String = "Default") -> some View {
        let current = selection.wrappedValue
        return Picker(title, selection: selection) {
            ForEach(options.contains(current) ? options : options + [current], id: \.self) { option in
                Text(option.isEmpty ? empty : option).tag(option)
            }
        }
    }

    @ViewBuilder
    private var hysteriaSections: some View {
        Section("Hysteria 2") {
            secret("Password", $draft.password)
            Toggle("Salamander obfuscation", isOn: $draft.obfs)
            if draft.obfs { secret("Obfuscation password", $draft.obfsPassword) }
        }
        Section("Port Hopping") {
            TextField("Ports", text: $draft.hopPorts, prompt: Text("5000-6000 (off when empty)"))
            if !draft.hopPorts.trimmingCharacters(in: .whitespaces).isEmpty {
                TextField("Interval (seconds)", text: $draft.hopInterval)
            }
        }
        Section("TLS") {
            TextField("SNI", text: $draft.sni, prompt: Text("(server address)"))
            TextField("ALPN", text: $draft.alpn, prompt: Text("h3"))
            secret("Certificate pin (SHA-256)", $draft.pinnedCert, prompt: "(none)")
            Toggle("Allow insecure", isOn: $draft.allowInsecure)
        }
    }

    @ViewBuilder
    private var wireguardSections: some View {
        Section("WireGuard") {
            secret("Private key", $draft.wgSecretKey)
            TextField("Addresses", text: $draft.wgAddresses, prompt: Text("10.0.0.2/32, fd00::2/128"))
            TextField("MTU", text: $draft.wgMTU, prompt: Text("(default)"))
            TextField("Reserved", text: $draft.wgReserved, prompt: Text("0, 0, 0"))
        }
        Section("Peer") {
            secret("Public key", $draft.wgPublicKey)
            secret("Pre-shared key", $draft.wgPreSharedKey, prompt: "(none)")
            TextField("Allowed IPs", text: $draft.wgAllowedIPs, prompt: Text("0.0.0.0/0, ::/0"))
            TextField("Keep-alive (seconds)", text: $draft.wgKeepAlive, prompt: Text("(off)"))
        }
    }

    private static let transportTitles = [
        "raw": "TCP (raw)", "ws": "WebSocket", "grpc": "gRPC", "httpupgrade": "HTTPUpgrade", "xhttp": "XHTTP", "kcp": "mKCP",
    ]

    private var transportSection: some View {
        Section("Transport") {
            Picker("Transport", selection: $draft.transport) {
                ForEach(ServerDraft.transports, id: \.self) { Text(Self.transportTitles[$0] ?? $0).tag($0) }
            }
            // Raw and mKCP each have their own kinds of header.
            .onChange(of: draft.transport) { draft.headerType = "none" }
            switch draft.transport {
            case "ws", "httpupgrade":
                TextField("Path", text: $draft.path, prompt: Text("/"))
                TextField("Host", text: $draft.host, prompt: Text("(server address)"))
            case "grpc":
                TextField("Service name", text: $draft.serviceName)
                TextField("Authority", text: $draft.authority, prompt: Text("(none)"))
                Toggle("Multi mode", isOn: $draft.grpcMulti)
            case "xhttp":
                TextField("Path", text: $draft.path, prompt: Text("/"))
                TextField("Host", text: $draft.host, prompt: Text("(server address)"))
                picker("Mode", $draft.xhttpMode, ServerDraft.xhttpModes)
                TextField("Extra (JSON)", text: $draft.xhttpExtra, prompt: Text("{ }"), axis: .vertical)
                    .lineLimit(1...6)
                    .font(.callout.monospaced())
            case "kcp":
                picker("Header", $draft.headerType, ServerDraft.kcpHeaders)
                secret("Seed", $draft.kcpSeed, prompt: "(none)")
            default:
                picker("Header", $draft.headerType, ["none", "http"])
                if draft.headerType == "http" {
                    TextField("Host", text: $draft.host, prompt: Text("a.example.com, b.example.com"))
                    TextField("Path", text: $draft.path, prompt: Text("/"))
                }
            }
        }
    }

    private var securitySection: some View {
        Section("Security") {
            Picker("Security", selection: $draft.security) {
                Text("None").tag("none")
                Text("TLS").tag("tls")
                Text("REALITY").tag("reality")
            }
            switch draft.security {
            case "tls":
                TextField("SNI", text: $draft.sni, prompt: Text("(server address)"))
                picker("Fingerprint", $draft.fingerprint, ServerDraft.fingerprints, empty: "None")
                TextField("ALPN", text: $draft.alpn, prompt: Text("h2, http/1.1"))
                Toggle("Allow insecure", isOn: $draft.allowInsecure)
                secret("Certificate pin (SHA-256)", $draft.pinnedCert, prompt: "(none)")
                TextField("Verify certificate name", text: $draft.verifyName, prompt: Text("(none)"))
                secret("ECH config", $draft.ech, prompt: "(none)")
            case "reality":
                TextField("SNI", text: $draft.sni, prompt: Text("www.example.com"))
                picker("Fingerprint", $draft.fingerprint, ServerDraft.fingerprints, empty: "chrome")
                secret("Public key", $draft.realityPublicKey)
                secret("Short ID", $draft.realityShortID, prompt: "(none)")
                TextField("Spider X", text: $draft.realitySpiderX, prompt: Text("(none)"))
                secret("ML-DSA-65 verify key", $draft.realityMldsa, prompt: "(none)")
            default:
                EmptyView()
            }
        }
    }

    private var muxSection: some View {
        Section {
            Toggle("Mux", isOn: $draft.muxEnabled)
            if draft.muxEnabled {
                TextField("Connections", text: $draft.muxConcurrency)
                TextField("XUDP connections", text: $draft.xudpConcurrency)
                picker("UDP port 443 (QUIC)", $draft.xudpProxyUDP443, ServerDraft.udp443Policies)
            }
        } footer: {
            Text("Carries many connections inside one. Not for servers that use the Vision flow.")
        }
    }
}

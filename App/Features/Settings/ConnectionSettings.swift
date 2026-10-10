import SwiftUI
import V2MacCore

/// How the core reaches a server: live switching, TLS fragment, noise packets and DNS.
struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("liveSwitch") private var liveSwitch = true
    @AppStorage("allowInsecure") private var allowInsecure = false
    @AppStorage("fragmentEnabled") private var fragmentEnabled = false
    @AppStorage("fragmentPackets") private var fragmentPackets = FragmentSettings.Packets.tlsHello.rawValue
    @AppStorage("fragmentLength") private var fragmentLength = FragmentSettings.defaultLength
    @AppStorage("fragmentInterval") private var fragmentInterval = FragmentSettings.defaultInterval
    @AppStorage("noiseEnabled") private var noiseEnabled = false
    @AppStorage("noisePacket") private var noisePacket = NoiseSettings.defaultPacket
    @AppStorage("noiseDelay") private var noiseDelay = NoiseSettings.defaultDelay
    @AppStorage("dnsEnabled") private var dnsEnabled = false
    @AppStorage("dnsServers") private var dnsServers = DNSSettings.defaultServers.joined(separator: ", ")
    @AppStorage("dnsQueryStrategy") private var dnsQueryStrategy = DNSQueryStrategy.useIP.rawValue
    @State private var pending: Task<Void, Never>?

    /// Everything here that needs a new core config.
    private var coreSettings: [String] {
        ["\(allowInsecure)", "\(fragmentEnabled)", fragmentPackets, fragmentLength, fragmentInterval,
         "\(noiseEnabled)", noisePacket, noiseDelay, "\(dnsEnabled)", dnsServers, dnsQueryStrategy]
    }

    var body: some View {
        Form {
            Section {
                Toggle("Switch servers without restarting", isOn: $liveSwitch)
            } footer: {
                note("Picking another server replaces it inside the running core, so the local port stays up. Full Xray configs always restart.")
            }
            Section {
                Toggle("Allow insecure servers", isOn: $allowInsecure)
            } footer: {
                note("For servers whose link says allowInsecure, usually ones with a self-signed certificate. V2Mac asks such a server for its certificate each time it connects and accepts that one without checking who issued it, so someone between you and the server could pose as it. Other servers are not affected.")
            }
            Section {
                Toggle("TLS fragment", isOn: $fragmentEnabled)
                if fragmentEnabled {
                    Picker("Split", selection: $fragmentPackets) {
                        Text("TLS hello").tag(FragmentSettings.Packets.tlsHello.rawValue)
                        Text("First packets").tag(FragmentSettings.Packets.firstPackets.rawValue)
                    }
                    rangeField("Piece size (bytes)", text: $fragmentLength, example: FragmentSettings.defaultLength)
                    rangeField("Pause (ms)", text: $fragmentInterval, example: FragmentSettings.defaultInterval)
                }
                Toggle("Noise packets", isOn: $noiseEnabled)
                if noiseEnabled {
                    rangeField("Packet size (bytes)", text: $noisePacket, example: NoiseSettings.defaultPacket)
                    rangeField("Pause (ms)", text: $noiseDelay, example: NoiseSettings.defaultDelay)
                }
            } header: {
                Text("Anti-filtering")
            } footer: {
                note("Fragment splits the start of each connection to the server; noise sends random packets ahead of UDP-based servers. They help on some networks and break connections on others, so turn them off if servers stop answering.")
            }
            Section {
                Toggle("Use custom DNS", isOn: $dnsEnabled)
                if dnsEnabled {
                    TextField("Servers", text: $dnsServers, axis: .vertical)
                        .lineLimit(1...4)
                    Picker("Addresses", selection: $dnsQueryStrategy) {
                        ForEach(DNSQueryStrategy.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
            } header: {
                Text("DNS")
            } footer: {
                note("Separate servers with commas. They are used for routing decisions and for traffic that goes direct; traffic through a server is resolved by that server. A full Xray config with its own DNS keeps it.")
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: fragmentEnabled)
        .animation(.default, value: noiseEnabled)
        .animation(.default, value: dnsEnabled)
        .onChange(of: coreSettings) { restartSoon() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rangeField(_ title: String, text: Binding<String>, example: String) -> some View {
        TextField(title, text: text, prompt: Text(example))
        if !RangeText.isValid(text.wrappedValue) {
            Text("Enter a number or a range such as \(example). Until then \(example) is used.")
                .font(.caption).foregroundStyle(.red)
        }
    }

    /// Typing fires many changes; restart once after they settle.
    private func restartSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            model.connection.reconnectIfRunning()
        }
    }
}

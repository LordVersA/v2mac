import SwiftUI
import V2MacCore

/// Tries each fragment setting against the active server and offers the best one (spec 8.4).
struct FragmentTunerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fragmentEnabled") private var fragmentEnabled = false
    @AppStorage("fragmentPackets") private var fragmentPackets = FragmentSettings.Packets.tlsHello.rawValue
    @AppStorage("fragmentLength") private var fragmentLength = FragmentSettings.defaultLength
    @AppStorage("fragmentInterval") private var fragmentInterval = FragmentSettings.defaultInterval
    @State private var results: [String: Int?] = [:]
    @State private var best: FragmentTuner.Trial?
    @State private var finished = false

    private var server: Profile? { Prefs.activeProfileID.flatMap(model.profile(id:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find Fragment Settings").font(.title2.weight(.semibold))
            if let server {
                Text("Each setting is tried twice against \(server.name), each through its own test core. Your connection is not touched.")
                    .font(.callout).foregroundStyle(.secondary)
                List(FragmentTuner.candidates.map { FragmentTuner.Trial(fragment: $0, ms: nil) }) { trial in
                    HStack {
                        Text(Self.title(trial.fragment))
                        Spacer()
                        switch results[trial.id] {
                        case .none: ProgressView().controlSize(.small)
                        case .some(.none): Text("No answer").foregroundStyle(.red)
                        case .some(.some(let ms)): Text("\(ms) ms").monospacedDigit().foregroundStyle(trial.id == best?.id ? .green : .secondary)
                        }
                    }
                }
                .listStyle(.inset)
                if finished {
                    if let best {
                        Label(best.fragment == nil ? "This server works without a fragment." : "Best: \(Self.title(best.fragment)).",
                              systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label("No setting got an answer. The server may be down or blocked another way.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("Choose a server first: the settings are tried against the server you connect with.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            HStack {
                Spacer()
                Button(finished ? "Close" : "Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use These Settings") { apply(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(best == nil)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
        .task { await run() }
    }

    private func run() async {
        guard let server, let config = server.config else { return }
        let target = LatencyTarget(id: server.id, config: config, kind: server.kind)
        await model.latency.beforeTesting(KillSwitch.hosts(in: config, kind: server.kind))
        let noise = Prefs.dialer.noise
        let options = Prefs.latencyOptions
        let testers = Dictionary(uniqueKeysWithValues: FragmentTuner.candidates.map { fragment in
            (FragmentTuner.Trial(fragment: fragment, ms: nil).id, model.latency.tester(options: options, dialer: DialerSettings(fragment: fragment, noise: noise)))
        })
        let trials = await FragmentTuner.run(target, tester: { testers[FragmentTuner.Trial(fragment: $0, ms: nil).id]! }) { trial in
            await MainActor.run { results[trial.id] = .some(trial.ms) }
        }
        guard !Task.isCancelled else { return }
        best = FragmentTuner.pick(trials)
        finished = true
        #if DEBUG
        print("[v2mac-debug] fragment tuner:", trials.map { "\($0.id)=\($0.ms.map(String.init) ?? "-")" }.joined(separator: ", "), "best:", best?.id ?? "none")
        #endif
    }

    private func apply() {
        guard let best else { return }
        fragmentEnabled = best.fragment != nil
        if let fragment = best.fragment {
            fragmentPackets = fragment.packets.rawValue
            fragmentLength = fragment.length
            fragmentInterval = fragment.interval
        }
    }

    static func title(_ fragment: FragmentSettings?) -> String {
        guard let fragment else { return String(localized: "No fragment") }
        let split = fragment.packets == .tlsHello ? String(localized: "TLS hello") : String(localized: "First packets")
        return String(localized: "\(split), \(fragment.length) bytes, \(fragment.interval) ms")
    }
}

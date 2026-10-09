import SwiftUI
import V2MacCore

struct SubscriptionSettings: View {
    @AppStorage("autoUpdateSubscriptions") private var auto = true
    @AppStorage("subscriptionUpdateViaProxy") private var viaProxy = false
    @AppStorage("defaultIntervalHours") private var hours = 12
    @AppStorage("userAgent") private var userAgent = ""
    @AppStorage("latencyURL") private var url = "https://www.gstatic.com/generate_204"
    @AppStorage("latencyTimeout") private var timeout = 8.0
    @AppStorage("latencyConcurrency") private var concurrency = 8
    @AppStorage("speedTestURL") private var speedURL = Prefs.defaultSpeedURL

    var body: some View {
        Form {
            Section {
                Toggle("Auto-update subscriptions", isOn: $auto)
                Picker("Auto-update route", selection: $viaProxy) {
                    Text("Without proxy").tag(false)
                    Text("Via proxy").tag(true)
                }
                .disabled(!auto)
                Stepper("Default interval: \(hours) h", value: $hours, in: 1...168)
                    .disabled(!auto)
                TextField("User-Agent", text: $userAgent, prompt: Text("v2mac/\(Prefs.appVersion)"))
            } header: {
                Text("Subscriptions")
            } footer: {
                Text("The default interval is used when the provider doesn't send one.")
            }

            Section {
                TextField("Test URL", text: $url)
                Stepper("Timeout: \(Int(timeout)) s", value: $timeout, in: 2...30, step: 1)
                Stepper("Concurrency: \(concurrency)", value: $concurrency, in: 1...32)
                TextField("Speed test file", text: $speedURL)
            } header: {
                Text("Server testing")
            } footer: {
                Text("The speed test downloads a large file through each server. It stops as soon as the speed levels off, so the whole file is never fetched.")
            }
        }
        .formStyle(.grouped)
    }
}

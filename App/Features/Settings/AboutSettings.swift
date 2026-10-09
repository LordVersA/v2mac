import SwiftUI
import V2MacCore

struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("V2Mac").font(.title2.bold())
                    Text("Version \(Prefs.appVersion)").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                HStack(spacing: 4) {
                    Spacer()
                    Text("Made with")
                    Image(systemName: "heart.fill").foregroundStyle(.red).accessibilityLabel("love")
                    Text("by")
                    Link("LordVersa", destination: URL(string: "https://github.com/LordVersA")!)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Xray-core") {
                    Link("github.com/XTLS/Xray-core", destination: URL(string: "https://github.com/XTLS/Xray-core")!)
                }
            } footer: {
                Text("V2Mac is GPL-3.0 software. It bundles Xray-core (MPL-2.0) and v2fly/Loyalsoldier rule data; see THIRD_PARTY.md for licences and attributions.")
            }
        }
        .formStyle(.grouped)
    }
}

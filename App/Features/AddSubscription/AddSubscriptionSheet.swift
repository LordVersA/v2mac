import SwiftUI
import V2MacCore

struct AddSubscriptionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var name = ""
    @State private var viaProxy = false
    @State private var isFetching = false
    @State private var errorMessage: String?
    @State private var duplicateID: UUID?
    /// The last direct fetch failed on the network, so the host may only be reachable through a proxy.
    @State private var directFetchBlocked = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Subscription").font(.headline)

            Form {
                TextField("URL", text: $url, prompt: Text("https://sub.example.com/abc123"))
                    .focused($urlFocused)
                TextField("Name", text: $name, prompt: Text("(auto)"))
                Toggle("Fetch via proxy", isOn: $viaProxy)
                    .disabled(!model.connection.isRunning)
                if !model.connection.isRunning {
                    Text("Connect to a server first to fetch through it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(isFetching)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                if directFetchBlocked {
                    if model.connection.isRunning {
                        Text("This link may only be reachable through your proxy.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Try via Proxy") { viaProxy = true; add() }
                    } else {
                        Text("This link may only be reachable through a VPN or proxy. Connect to a server first, then turn on “Fetch via proxy”.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let duplicateID {
                    Button("Update Existing") {
                        model.sidebarSelection = .group(duplicateID)
                        Task { await model.subscriptions.update(groupID: duplicateID, viaProxy: viaProxy) }
                        dismiss()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                if isFetching {
                    ProgressView().controlSize(.small).frame(width: 60)
                } else {
                    Button("Add") { add() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            urlFocused = true
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let u = URL(string: clip), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil {
                url = clip
            }
        }
    }

    private func add() {
        errorMessage = nil
        duplicateID = nil
        directFetchBlocked = false
        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                let id = try await model.subscriptions.add(urlString: url, name: name, viaProxy: viaProxy)
                model.sidebarSelection = .group(id)
                dismiss()
            } catch let AddSubscriptionError.duplicate(id) {
                errorMessage = AddSubscriptionError.duplicate(id).localizedDescription
                duplicateID = id
            } catch {
                errorMessage = error.localizedDescription
                if !viaProxy, case SubscriptionError.network = error { directFetchBlocked = true }
            }
        }
    }
}

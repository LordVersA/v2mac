import SwiftUI
import V2MacCore

struct AddSubscriptionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var kind = AddDraft.Kind.custom
    @State private var url = ""
    @State private var configText = ""
    @State private var name = ""
    @State private var viaProxy = false
    @State private var isFetching = false
    @State private var errorMessage: String?
    @State private var duplicateID: UUID?
    /// The last direct fetch failed on the network, so the host may only be reachable through a proxy.
    @State private var directFetchBlocked = false
    @FocusState private var urlFocused: Bool
    @FocusState private var configFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .subscription ? "Add Subscription" : "Add Custom Configs").font(.headline)

            Form {
                Picker("Type", selection: $kind.animation(.snappy)) {
                    Text("Subscription URL").tag(AddDraft.Kind.subscription)
                    Text("Custom Config").tag(AddDraft.Kind.custom)
                }
                // Separate groups so the fields of one type blur out as the other's blur in.
                switch kind {
                case .subscription:
                    Group {
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
                    .transition(.blurReplace)
                case .custom:
                    Group {
                        // A text field rather than a text editor: it never swaps in smart quotes, which break JSON.
                        TextField("Configs", text: $configText, prompt: Text("Paste one or more share links or Xray JSON configs"), axis: .vertical)
                            .lineLimit(12...12)
                            .font(.callout.monospaced())
                            .focused($configFocused)
                        Text("They are added to the Custom Configs group.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .transition(.blurReplace)
                }
            }
            .disabled(isFetching)
            .onChange(of: kind) { clearError() }

            if let errorMessage {
                VStack(alignment: .leading, spacing: 16) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
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
                .transition(.opacity)
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
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .animation(.snappy, value: errorMessage)
        .animation(.snappy, value: isFetching)
        .onAppear(perform: start)
    }

    private var input: String { kind == .subscription ? url : configText }

    private func start() {
        let draft = model.addDraft
        model.addDraft = AddDraft()
        kind = draft.kind
        configText = draft.configText
        errorMessage = draft.error
        if kind == .subscription { urlFocused = true } else { configFocused = true }
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           AddDraft.isSubscriptionURL(clip) {
            url = clip
        }
    }

    private func clearError() {
        errorMessage = nil
        duplicateID = nil
        directFetchBlocked = false
    }

    private func add() {
        clearError()
        isFetching = true
        switch kind {
        case .subscription: addSubscription()
        case .custom: addCustom()
        }
    }

    private func addCustom() {
        Task {
            defer { isFetching = false }
            do {
                model.sidebarSelection = .group(try await model.subscriptions.addCustom(text: configText))
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addSubscription() {
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

import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ServerGroup.sortIndex) private var groups: [ServerGroup]
    @Query private var profiles: [Profile]

    @State private var editing: ServerGroup?
    @State private var pendingDelete: ServerGroup?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("All", systemImage: "square.stack.3d.up")
                .badge(profiles.count)
                .tag(SidebarItem.all)

            // Pasted configs live in their own group, apart from the subscriptions.
            ForEach(groups.filter(\.isManual)) { group in
                SidebarRow(group: group)
                    .tag(SidebarItem.group(group.id))
                    .contextMenu { menu(for: group) }
            }

            Section("Subscriptions") {
                let subscriptions = groups.filter { !$0.isManual }
                ForEach(subscriptions) { group in
                    SidebarRow(group: group)
                        .tag(SidebarItem.group(group.id))
                        .contextMenu { menu(for: group) }
                }
                .onMove { source, destination in
                    model.moveGroups(subscriptions, from: source, to: destination)
                }
            }
        }
        .sheet(item: $editing) { group in
            GroupEditSheet(group: group)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { group in
            Button("Delete", role: .destructive) { model.deleteGroup(group) }
        } message: { group in
            if let active = model.connection.activeServer, group.profiles.contains(where: { $0.id == active.id }) {
                Text("This group contains the active server. V2Mac will disconnect.")
            } else {
                Text("Its servers will be removed.")
            }
        }
    }

    @ViewBuilder
    private func menu(for group: ServerGroup) -> some View {
        if group.isManual {
            Button("Rename…") { editing = group }
        } else {
            subscriptionMenu(for: group)
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = group }
    }

    @ViewBuilder
    private func subscriptionMenu(for group: ServerGroup) -> some View {
        Button("Update without Proxy") {
            Task { await model.subscriptions.update(groupID: group.id, viaProxy: false) }
        }
        Button("Update via Proxy") {
            Task { await model.subscriptions.update(groupID: group.id, viaProxy: true) }
        }
        .disabled(!model.connection.isRunning)
        Divider()
        Button("Edit…") { editing = group }
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(group.subscriptionURL, forType: .string)
        }
        Toggle("Auto-update", isOn: Binding(
            get: { group.autoUpdateEnabled },
            set: { group.autoUpdateEnabled = $0; try? model.context.save() }
        ))
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let group: ServerGroup

    private var isUpdating: Bool { model.subscriptions.updatingGroupIDs.contains(group.id) }

    var body: some View {
        HStack {
            Label {
                Text(group.name)
            } icon: {
                // The sync arrows appear, turning, only while this group is being fetched.
                Image(systemName: isUpdating ? "arrow.triangle.2.circlepath" : (group.isManual ? "doc.on.clipboard" : "dot.radiowaves.up.forward"))
                    .symbolEffect(.rotate, isActive: isUpdating)
                    .contentTransition(.symbolEffect(.replace))
            }
            if !isUpdating, let error = group.lastUpdateError {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
                    .accessibilityLabel("Last update failed: \(error)")
            }
        }
        // A zero badge is hidden, which leaves room for the warning.
        .badge(group.lastUpdateError == nil || isUpdating ? group.profiles.count : 0)
    }
}

struct GroupEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ServerGroup

    @State private var name = ""
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group.isManual ? "Rename Group" : "Edit Subscription").font(.headline)
            Form {
                TextField("Name", text: $name)
                if !group.isManual { TextField("URL", text: $url) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { group.name = trimmed }
                    let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !u.isEmpty { group.subscriptionURL = u }
                    try? model.context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            name = group.name
            url = group.subscriptionURL
        }
    }
}

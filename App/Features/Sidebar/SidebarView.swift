import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ServerGroup.sortIndex) private var groups: [ServerGroup]
    @Query(filter: #Predicate<Profile> { $0.isFavorite }) private var favorites: [Profile]

    @State private var editing: ServerGroup?
    @State private var pendingDelete: ServerGroup?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("All", systemImage: "square.stack.3d.up")
                .badge(groups.reduce(0) { $0 + $1.profiles.count })
                .tag(SidebarItem.all)

            Label("Favorites", systemImage: "star")
                .badge(favorites.count)
                .tag(SidebarItem.favorites)

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

            SidebarRecents()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarTools() }
        .sheet(item: $editing) { group in
            GroupEditSheet(group: group)
        }
        .confirmationDialog(
            pendingDelete?.isManual == true ? "Delete all configs in “\(pendingDelete?.name ?? "")”?" : "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { group in
            Button("Delete", role: .destructive) { withAnimation { model.deleteGroup(group) } }
        } message: { group in
            if let active = model.connection.activeServer, group.profiles.contains(where: { $0.id == active.id }) {
                Text("This group contains the active server. V2Mac will disconnect.")
            } else if group.isManual {
                Text("The group itself stays in the sidebar.")
            } else {
                Text("Its servers will be removed.")
            }
        }
    }

    @ViewBuilder
    private func menu(for group: ServerGroup) -> some View {
        if group.isManual {
            Button("Rename…") { editing = group }
            Divider()
            // The group itself stays; only its servers can go.
            Button("Delete All Configs…", role: .destructive) { pendingDelete = group }
                .disabled(group.profiles.isEmpty)
        } else {
            subscriptionMenu(for: group)
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = group }
        }
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
            set: { group.autoUpdateEnabled = $0; model.save() }
        ))
    }
}

/// The servers a connection last came up on, newest first, at the end of the sidebar. A click
/// connects to one. On its own, with its own query, so that delay tests do not rebuild the sidebar.
private struct SidebarRecents: View {
    @Environment(AppModel.self) private var model
    @Query private var profiles: [Profile]

    var body: some View {
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = model.connection.recentServerIDs.compactMap { byID[$0] }.filter { !$0.isStale }.prefix(5)
        if !recent.isEmpty {
            Section("Recent") {
                ForEach(recent) { profile in
                    let name = ServerName(profile.name)
                    let isActive = profile.id == model.connection.activeServer?.id
                    Button {
                        model.activate(profile)
                    } label: {
                        // Two lines, so neither the server nor its subscription is cut short by the other.
                        HStack(spacing: 6) {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name.title).lineLimit(1)
                                    if let group = profile.group {
                                        HStack(spacing: 4) {
                                            GroupDot(color: group.tint)
                                            Text(group.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                            } icon: {
                                Text(name.flag ?? "🌐")
                            }
                            Spacer(minLength: 4)
                            if isActive {
                                Circle()
                                    .fill(model.connection.isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                                    .frame(width: 7, height: 7)
                                    .accessibilityLabel(model.connection.isRunning ? "Connected" : "Active")
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(isActive ? "The active server" : "Connect to \(name.title)")
                }
            }
        }
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let group: ServerGroup

    private var isUpdating: Bool { model.subscriptions.updatingGroupIDs.contains(group.id) }

    var body: some View {
        HStack {
            Label {
                Text(group.displayName)
            } icon: {
                // The sync arrows appear, turning, only while this group is being fetched.
                Image(systemName: isUpdating ? "arrow.triangle.2.circlepath" : (group.isManual ? "doc.on.clipboard" : "dot.radiowaves.up.forward"))
                    .symbolEffect(.rotate, isActive: isUpdating)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(group.tint.color)
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
    @State private var color = GroupColor.gray

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group.isManual ? "Rename Group" : "Edit Subscription").font(.headline)
            Form {
                TextField("Name", text: $name)
                if !group.isManual { TextField("URL", text: $url) }
                LabeledContent("Color") { GroupColorPicker(selection: $color) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { group.name = trimmed }
                    let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !u.isEmpty { group.subscriptionURL = u }
                    if color != group.tint { group.colorName = color.rawValue }
                    model.save()
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
            color = group.tint
        }
    }
}

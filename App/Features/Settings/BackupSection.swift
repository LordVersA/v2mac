import AppKit
import SwiftUI
import UniformTypeIdentifiers
import V2MacCore

extension UTType {
    /// A `.v2m` backup (spec 12.9), declared in Info.plist.
    static let v2macBackup = UTType(exportedAs: "io.github.lordversa.v2mac.backup", conformingTo: .data)
}

struct BackupSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            HStack {
                Button("Export Backup…") { Task { await BackupFlow.export(model) } }
                Button("Restore Backup…") { BackupFlow.restore(model, from: nil) }
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("A .v2m file with your subscriptions and their servers, pasted configs, favorites and settings. It holds subscription links and server passwords, so keep it private. The local proxy password and registered WARP credentials are not in it. Restoring adds what is missing here and takes the backup's settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The panels and questions around a backup; `AppModel` does the work.
@MainActor
enum BackupFlow {
    static func export(_ model: AppModel) async {
        guard await OwnerCheck.confirm(String(localized: "export a backup with your servers")) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.v2macBackup]
        panel.nameFieldStringValue = "V2Mac \(Date().formatted(.iso8601.year().month().day())).\(Backup.fileExtension)"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.makeBackup().fileData().write(to: url, options: .atomic)
        } catch {
            show(String(localized: "The backup could not be saved."), detail: error.localizedDescription)
        }
    }

    /// Asks for a file when `url` is nil, then what the backup holds before restoring it.
    static func restore(_ model: AppModel, from url: URL?) {
        NSApp.activate()
        var file = url
        if file == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.v2macBackup]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK else { return }
            file = panel.url
        }
        guard let file else { return }
        let backup: Backup
        do {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size < 50_000_000 else { throw Backup.ReadError.notABackup }
            backup = try Backup.read(Data(contentsOf: file))
        } catch {
            show(String(localized: "This backup cannot be restored."), detail: error.localizedDescription)
            return
        }
        let servers = backup.groups.reduce(0) { $0 + $1.servers.count }
        let subscriptions = backup.groups.filter { !$0.subscriptionURL.isEmpty }.count
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore this backup?")
        alert.informativeText = String(localized: "Made on \(backup.created.formatted(date: .long, time: .shortened)) with V2Mac \(backup.app): \(subscriptions) subscriptions and \(servers) servers. What is missing here is added, nothing is removed, and the settings are replaced by the backup's.")
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let added = model.restore(backup)
        show(String(localized: "Backup restored"),
             detail: String(localized: "Added \(added.groups) subscriptions and \(added.servers) servers. Settings were restored."))
    }

    private static func show(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

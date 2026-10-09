import Foundation
import Observation
import V2MacCore

@MainActor @Observable
final class RegionPackService {
    enum Status: Equatable {
        case notInstalled
        case installing
        case installed(Date?)
        case failed(String)
    }

    let packs: [RegionPackDefinition]
    private(set) var statuses: [String: Status] = [:]
    private(set) var enabledIDs: Set<String> = Prefs.enabledRegionPacks

    private var schedulerTask: Task<Void, Never>?

    /// Called after a pack that is in use changed on disk, so the core can restart.
    var onChangeInUse: (() -> Void)?
    /// Routes for downloads, in order of preference (spec 11).
    var downloadRoutes: () -> [FetchRoute] = { [.direct] }

    init() {
        if let url = Bundle.main.url(forResource: "RegionPacks", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let list = try? RegionPackDefinition.decodeList(data) {
            packs = list
        } else {
            packs = []
        }
        for pack in packs { statuses[pack.id] = diskStatus(pack) }
    }

    private func diskStatus(_ pack: RegionPackDefinition) -> Status {
        guard RegionPackInstaller.isInstalled(pack, assetDirectory: AppPaths.assetsDirectory) else { return .notInstalled }
        let file = AppPaths.assetsDirectory.appendingPathComponent(pack.geosite.file)
        let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        return .installed(date)
    }

    func isUsable(_ pack: RegionPackDefinition) -> Bool {
        enabledIDs.contains(pack.id) && RegionPackInstaller.isInstalled(pack, assetDirectory: AppPaths.assetsDirectory)
    }

    /// Enabled and downloaded packs, as routing rules.
    var usableRoutes: [RegionRoute] { packs.filter(isUsable).map(\.route) }
    var hasUsablePack: Bool { packs.contains(where: isUsable) }

    func status(_ pack: RegionPackDefinition) -> Status { statuses[pack.id] ?? .notInstalled }

    /// Downloads and verifies the pack, then marks it enabled.
    func enable(_ pack: RegionPackDefinition) async {
        guard await install(pack) else { return }
        enabledIDs.insert(pack.id)
        Prefs.enabledRegionPacks = enabledIDs
        onChangeInUse?()
    }

    /// Updates enabled packs whose interval has elapsed: shortly after launch, then hourly.
    func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.updateDuePacks()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func updateDuePacks(now: Date = Date()) async {
        for pack in packs where enabledIDs.contains(pack.id) {
            guard let interval = Prefs.packUpdateInterval(pack.id).seconds else { continue }
            guard case .installed(let date) = status(pack) else { continue }
            if let date, now.timeIntervalSince(date) < interval { continue }
            await updateNow(pack)
        }
    }

    func disable(_ pack: RegionPackDefinition) {
        let wasUsable = isUsable(pack)
        enabledIDs.remove(pack.id)
        Prefs.enabledRegionPacks = enabledIDs
        RegionPackInstaller.remove(pack, assetDirectory: AppPaths.assetsDirectory)
        statuses[pack.id] = .notInstalled
        if wasUsable { onChangeInUse?() }
    }

    func updateNow(_ pack: RegionPackDefinition) async {
        guard await install(pack), enabledIDs.contains(pack.id) else { return }
        onChangeInUse?()
    }

    private func install(_ pack: RegionPackDefinition) async -> Bool {
        if statuses[pack.id] == .installing { return false }
        statuses[pack.id] = .installing
        do {
            try await RegionPackInstaller.install(
                pack,
                assetDirectory: AppPaths.assetsDirectory,
                downloader: FileDownloader(routes: downloadRoutes())
            )
            statuses[pack.id] = diskStatus(pack)
            return true
        } catch {
            // Any previously installed copy stays in place and keeps working.
            statuses[pack.id] = .failed(error.localizedDescription)
            return false
        }
    }
}

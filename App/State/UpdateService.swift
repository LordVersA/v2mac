import AppKit
import Foundation
import Observation
import V2MacCore

/// Core updates (manual, spec 11.1) and the app update check (spec 11.3).
@MainActor @Observable
final class UpdateService {
    enum CoreStatus: Equatable {
        case idle
        case checking
        case upToDate
        case available(CoreRelease)
        case installing
        case installed(String)
        case failed(String)
    }

    enum AppStatus: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        /// Downloading and checking the release; the app restarts when it is ready.
        case installing(AppRelease)
        case installFailed(AppRelease, String)
        case unavailable(String)
    }

    /// A background check found a newer release (spec 12.8).
    enum Found: Equatable {
        case app(String)
        case core(String)
    }
    @ObservationIgnored var onFound: @MainActor (Found) -> Void = { _ in }

    private(set) var coreStatus: CoreStatus = .idle
    private(set) var coreVersion: String?
    private(set) var coreIsUpdatedCopy = false
    private(set) var appStatus: AppStatus = .idle
    /// Progress of the app download while `appStatus` is `.installing`.
    private(set) var appProgress: DownloadProgress?
    /// Smoothed download speed in bytes per second.
    private(set) var appDownloadRate: Double?
    private(set) var coreProgress: DownloadProgress?
    private(set) var coreDownloadRate: Double?
    private var appRate = RateTracker()
    private var coreRate = RateTracker()

    /// Routes for downloads: local proxy first when the core runs, then direct (spec 11).
    var downloadRoutes: () -> [FetchRoute] = { [.direct] }
    /// Restarts the core after an install or revert.
    var restartCore: () -> Void = {}
    var isCoreRunning: () -> Bool = { false }

    private var schedulerTask: Task<Void, Never>?

    #if DEBUG
    /// `-debugFakeUpdates YES`: shows both update buttons without a real release.
    func fakeUpdates() {
        appStatus = .available(AppRelease(tag: "v9.9.9", pageURL: URL(string: "https://example.com")!))
        coreStatus = .available(CoreRelease(tag: "v99.0.0", publishedAt: nil, assetURL: URL(string: "https://example.com/x.zip")!, checksumURL: URL(string: "https://example.com/x.sha")!))
    }
    #endif

    var availableAppUpdate: AppRelease? {
        switch appStatus {
        case .available(let release), .installing(let release), .installFailed(let release, _): release
        default: nil
        }
    }

    var isInstallingApp: Bool {
        if case .installing = appStatus { return true }
        return false
    }

    /// `owner/name` of the app's own repository, from Info.plist. Empty disables the check.
    static var repository: String {
        (Bundle.main.object(forInfoDictionaryKey: "V2MacRepository") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var downloader: FileDownloader { FileDownloader(routes: downloadRoutes(), timeout: 30) }

    // MARK: Core

    func refreshCoreInfo() async {
        coreIsUpdatedCopy = FileManager.default.fileExists(atPath: AppPaths.coreDirectory.appendingPathComponent("xray").path)
        coreVersion = await SystemInfo.coreVersion(at: AppPaths.coreExecutable).map(VersionCompare.normalized)
    }

    /// `manual` shows progress and errors and ignores the once-per-24-hours throttle and the
    /// Settings switch; the background check stays silent unless it finds something.
    func checkCore(manual: Bool = true) async {
        guard coreStatus != .checking, coreStatus != .installing else { return }
        if !manual {
            guard UserDefaults.standard.bool(forKey: "checkAppUpdates") else { return }
            if let last = Prefs.lastCoreUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        }
        let previous = coreStatus
        if manual { coreStatus = .checking }
        if coreVersion == nil { await refreshCoreInfo() }
        do {
            let release = try await CoreUpdater.discover(downloader: downloader)
            Prefs.lastCoreUpdateCheck = Date()
            if VersionCompare.isNewer(release.tag, than: coreVersion ?? "") {
                coreStatus = .available(release)
                if !manual { onFound(.core(release.tag)) }
            } else if manual {
                coreStatus = .upToDate
            }
        } catch {
            coreStatus = manual ? .failed(error.localizedDescription) : previous
        }
    }

    var availableCoreUpdate: CoreRelease? {
        if case .available(let release) = coreStatus { release } else { nil }
    }

    func installCore(_ release: CoreRelease) async {
        guard coreStatus != .installing else { return }
        coreStatus = .installing
        coreProgress = nil
        coreDownloadRate = nil
        coreRate = RateTracker()
        let current = AppPaths.runDirectory.appendingPathComponent("config.json")
        do {
            let installed = try await CoreUpdater.install(
                release,
                downloader: downloader,
                coreDirectory: AppPaths.coreDirectory,
                assetDirectory: AppPaths.assetsDirectory,
                currentConfig: current,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.updateCoreProgress(progress) }
                }
            )
            coreStatus = .installed(installed.version)
            await refreshCoreInfo()
            if isCoreRunning() { restartCore() }
        } catch {
            // The running core and its files are untouched on any failure.
            coreStatus = .failed(error.localizedDescription)
        }
    }

    func revertToBundled() async {
        CoreUpdater.revert(coreDirectory: AppPaths.coreDirectory, assetDirectory: AppPaths.assetsDirectory)
        AppPaths.prepare()
        coreStatus = .idle
        await refreshCoreInfo()
        if isCoreRunning() { restartCore() }
    }

    // MARK: App

    /// `manual` ignores the once-per-24-hours throttle and the Settings switch.
    func checkApp(manual: Bool = false) async {
        let repo = Self.repository
        guard !repo.isEmpty else {
            if manual { appStatus = .unavailable("No update source is configured for this build.") }
            return
        }
        guard !isInstallingApp else { return }
        if !manual {
            guard UserDefaults.standard.bool(forKey: "checkAppUpdates") else { return }
            if let last = Prefs.lastAppUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        }
        appStatus = .checking
        do {
            let found = try await AppUpdateChecker.newer(than: Prefs.appVersion, repository: repo, downloader: downloader)
            Prefs.lastAppUpdateCheck = Date()
            appStatus = found.map(AppStatus.available) ?? .upToDate
            if !manual, let found { onFound(.app(found.tag)) }
        } catch {
            appStatus = manual ? .unavailable(error.localizedDescription) : .idle
        }
    }

    /// Downloads and verifies the release, then quits; a detached script swaps the app
    /// bundle and opens the new version. The installed app is untouched on any failure.
    func installApp(_ release: AppRelease) async {
        guard !isInstallingApp else { return }
        appStatus = .installing(release)
        appProgress = nil
        appDownloadRate = nil
        appRate = RateTracker()
        do {
            let target = Bundle.main.bundleURL
            try AppInstaller.checkReplaceable(target)
            guard let urls = AppInstaller.assetURLs(repository: Self.repository, tag: release.tag) else {
                throw CoreUpdateError.malformedResponse
            }
            let staged = try await AppInstaller.prepare(
                dmg: urls.dmg,
                checksum: urls.checksum,
                expectedVersion: release.version,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                downloader: FileDownloader(routes: downloadRoutes(), timeout: 60, maxBytes: 256 * 1024 * 1024),
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.updateProgress(progress) }
                }
            )
            do {
                try AppInstaller.scheduleSwap(staged, replacing: target, processID: ProcessInfo.processInfo.processIdentifier)
            } catch {
                try? FileManager.default.removeItem(at: staged.workDirectory)
                throw error
            }
            // Quitting waits for the core shutdown, which also needs the main actor and the main
            // queue. Called from here, or from a block on that queue, it would wait forever. A
            // run-loop perform does not occupy the queue.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        } catch {
            appStatus = .installFailed(release, error.localizedDescription)
        }
    }

    private func updateProgress(_ progress: DownloadProgress) {
        guard case .installing = appStatus else { return }
        appDownloadRate = appRate.add(progress.received)
        appProgress = progress
    }

    private func updateCoreProgress(_ progress: DownloadProgress) {
        guard coreStatus == .installing else { return }
        coreDownloadRate = coreRate.add(progress.received)
        coreProgress = progress
    }

    /// Checks shortly after launch, then re-evaluates hourly (the 24 h throttle applies).
    func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.checkApp()
                await self?.checkCore(manual: false)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

/// Smoothed bytes-per-second from cumulative byte counts.
struct RateTracker {
    private var sample: (time: ContinuousClock.Instant, bytes: Int64)?
    private var rate: Double?

    /// Feed the running total; returns the current speed, nil until one can be measured.
    mutating func add(_ bytes: Int64) -> Double? {
        let now = ContinuousClock.now
        if let sample, bytes >= sample.bytes {
            let seconds = (now - sample.time) / .seconds(1)
            if seconds >= 0.5 {
                let instant = Double(bytes - sample.bytes) / seconds
                rate = rate.map { $0 * 0.6 + instant * 0.4 } ?? instant
                self.sample = (now, bytes)
            }
        } else {
            // First report, or a fallback route restarted the download.
            sample = (now, bytes)
            rate = nil
        }
        return rate
    }
}

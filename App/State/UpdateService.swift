import AppKit
import Foundation
import CryptoKit
import Observation
import Synchronization
import V2MacCore

/// Core updates (manual, and the pinned range, spec 11.1) and app updates (spec 11.3).
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
        /// Downloading and checking the release.
        case installing(AppRelease)
        /// Checked and staged in `updates/`: it replaces this copy when the app quits.
        case ready(AppRelease)
        case installFailed(AppRelease, String)
        case unavailable(String)
    }

    /// A background check found a newer release (spec 12.6).
    enum Found: Equatable {
        case app(String)
        /// This launch is the first of a newer version.
        case updated(String)
    }
    @ObservationIgnored var onFound: @MainActor (Found) -> Void = { _ in }

    /// What the menu bar icon shows (docs/app-auto-update.md, "Icon").
    enum Badge: String {
        case available, ready
    }

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
    private var staged: AppInstaller.Staged?
    /// Once per session, so a pinned core that still does not suit (a broken build) is not fetched in a loop.
    private var fetchedPinnedCore = false
    /// Restart Now already started the swap; quitting must not start a second one.
    private var swapScheduled = false

    #if DEBUG
    /// `-debugFakeUpdates YES`: shows the update button without a real release.
    func fakeUpdates() {
        appStatus = .available(AppRelease(tag: "v9.9.9", pageURL: URL(string: "https://example.com")!))
        coreStatus = .available(CoreRelease(tag: "v99.0.0", publishedAt: nil, assetURL: URL(string: "https://example.com/x.zip")!, checksumURL: URL(string: "https://example.com/x.sha")!))
    }
    #endif

    var availableAppUpdate: AppRelease? {
        switch appStatus {
        case .available(let release), .installing(let release), .ready(let release), .installFailed(let release, _): release
        default: nil
        }
    }

    var badge: Badge? {
        #if DEBUG
        if let badge = UserDefaults.standard.string(forKey: "debugUpdateBadge").flatMap(Badge.init) { return badge }
        #endif
        if case .ready = appStatus { return .ready }
        return availableAppUpdate == nil ? nil : .available
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
        let updated = AppPaths.coreDirectory.appendingPathComponent("xray")
        let versionFile = AppPaths.coreDirectory.appendingPathComponent(CoreUpdater.versionFileName)
        let fm = FileManager.default
        // A core updated before the version file existed: record it, so the next connect can choose by range.
        if fm.fileExists(atPath: updated.path), !fm.fileExists(atPath: versionFile.path),
           let version = await SystemInfo.coreVersion(at: updated).map(VersionCompare.normalized) {
            try? Data(version.utf8).write(to: versionFile)
        }
        coreIsUpdatedCopy = AppPaths.coreExecutable == updated
        coreVersion = await SystemInfo.coreVersion(at: AppPaths.coreExecutable).map(VersionCompare.normalized)
        // Neither the updated nor the bundled core suits this build: fetch the pinned one.
        if let pin = AppPaths.corePin, let coreVersion, !pin.accepts(coreVersion), coreStatus != .installing, !fetchedPinnedCore {
            fetchedPinnedCore = true
            await installCore(pin.release, expectedSHA256: pin.sha256)
        }
    }

    /// Only on demand, from Settings → Core.
    func checkCore() async {
        guard coreStatus != .checking, coreStatus != .installing else { return }
        coreStatus = .checking
        if coreVersion == nil { await refreshCoreInfo() }
        do {
            let release = try await CoreUpdater.discover(downloader: downloader)
            coreStatus = VersionCompare.isNewer(release.tag, than: coreVersion ?? "") ? .available(release) : .upToDate
        } catch {
            coreStatus = .failed(error.localizedDescription)
        }
    }

    var availableCoreUpdate: CoreRelease? {
        if case .available(let release) = coreStatus { release } else { nil }
    }

    func installCore(_ release: CoreRelease, expectedSHA256: String? = nil) async {
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
                expectedSHA256: expectedSHA256,
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
            if manual { appStatus = .unavailable(String(localized: "No update source is configured for this build.")) }
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
            if case .ready(let release) = appStatus, release == found { return }
            appStatus = found.map(AppStatus.available) ?? .upToDate
            guard let found else { return }
            if Self.installsAutomatically {
                if await !stageApp(found), !manual { Prefs.lastAppUpdateCheck = nil } // retried on the next hourly pass
            } else if !manual {
                onFound(.app(found.tag))
            }
        } catch {
            appStatus = manual ? .unavailable(error.localizedDescription) : .idle
        }
    }

    /// Settings → General: download and stage in the background. Never in a Debug build, whose swap
    /// would replace V2MacDev.app with a release.
    static var installsAutomatically: Bool {
        #if DEBUG
        false
        #else
        UserDefaults.standard.bool(forKey: "installAppUpdates")
        #endif
    }

    /// Update Now: stages the release when it is not yet, then restarts into it.
    func installApp(_ release: AppRelease) async {
        guard !isInstallingApp else { return }
        if case .ready = appStatus { return restartNow() }
        #if DEBUG
        appStatus = .installFailed(release, "Debug builds never replace themselves.")
        #else
        if await stageApp(release) { restartNow() }
        #endif
    }

    /// Downloads the release (only the changed files, falling back to the DMG) and stages the checked app
    /// in `updates/`. The installed app is untouched until the swap.
    @discardableResult
    private func stageApp(_ release: AppRelease) async -> Bool {
        guard !isInstallingApp else { return false }
        appStatus = .installing(release)
        appProgress = nil
        appDownloadRate = nil
        appRate = RateTracker()
        do {
            let target = Bundle.main.bundleURL
            try AppInstaller.checkReplaceable(target)
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let onProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
                Task { @MainActor in self?.updateProgress(progress) }
            }
            let prepared: AppInstaller.Staged
            do {
                guard let manifest = AppInstaller.manifestURL(repository: Self.repository, tag: release.tag) else {
                    throw CoreUpdateError.malformedResponse
                }
                prepared = try await AppInstaller.prepareDelta(
                    manifest: manifest, expectedVersion: release.version, bundleIdentifier: bundleID, installed: target,
                    alternates: ["Contents/Helpers/xray": AppPaths.coreDirectory.appendingPathComponent("xray")],
                    work: AppPaths.updatesDirectory.appendingPathComponent("building"), downloader: downloader,
                    download: ResumableDownload(routes: downloadRoutes()), onProgress: onProgress
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Any failure of the file-by-file route: the whole DMG, as before.
                guard let urls = AppInstaller.assetURLs(repository: Self.repository, tag: release.tag) else {
                    throw CoreUpdateError.malformedResponse
                }
                prepared = try await AppInstaller.prepare(
                    dmg: urls.dmg, checksum: urls.checksum, expectedVersion: release.version, bundleIdentifier: bundleID,
                    downloader: FileDownloader(routes: downloadRoutes(), timeout: 60, maxBytes: 256 * 1024 * 1024),
                    onProgress: onProgress
                )
            }
            staged = try AppInstaller.stage(prepared, in: AppPaths.updatesDirectory)
            appStatus = .ready(release)
            return true
        } catch {
            appStatus = .installFailed(release, error.localizedDescription)
            return false
        }
    }

    /// Restart Now: quits, swaps the staged app in and opens it. The VPN drops for a few seconds.
    func restartNow() {
        guard let staged, !swapScheduled else { return }
        do {
            try AppInstaller.scheduleSwap(staged, replacing: Bundle.main.bundleURL, processID: ProcessInfo.processInfo.processIdentifier)
        } catch {
            appStatus = .unavailable(error.localizedDescription)
            return
        }
        swapScheduled = true
        // Quitting waits for the core shutdown, which also needs the main actor and the main
        // queue. Called from here, or from a block on that queue, it would wait forever. A
        // run-loop perform does not occupy the queue.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// From `applicationShouldTerminate`, after the core stopped: the staged app replaces this one once it
    /// has exited, and is not opened.
    func swapOnQuit() {
        guard let staged, !swapScheduled else { return }
        swapScheduled = (try? AppInstaller.scheduleSwap(staged, replacing: Bundle.main.bundleURL,
                                                        processID: ProcessInfo.processInfo.processIdentifier, openCommand: nil)) != nil
    }

    /// At launch, before anything starts: an update staged by the last session whose swap did not happen
    /// (logout killed the script). True when the swap was started; the caller then exits.
    static func swapStagedOnLaunch() -> Bool {
        #if DEBUG
        return false
        #else
        guard let staged = AppInstaller.staged(in: AppPaths.updatesDirectory, newerThan: Prefs.appVersion,
                                               bundleIdentifier: Bundle.main.bundleIdentifier ?? "") else { return false }
        return (try? AppInstaller.scheduleSwap(staged, replacing: Bundle.main.bundleURL,
                                               processID: ProcessInfo.processInfo.processIdentifier)) != nil
        #endif
    }

    #if DEBUG
    /// `-debugAppUpdate <files.json url>`: builds that release beside `-debugAppUpdateFrom` (default the installed
    /// V2Mac, only read) in the dev data folder, checked against `-debugAppUpdateKey` (a base64 public key) or the
    /// project's, and prints the result. Never stages or swaps.
    func debugPrepare(_ manifest: URL) async {
        let defaults = UserDefaults.standard
        let installed = URL(fileURLWithPath: defaults.string(forKey: "debugAppUpdateFrom") ?? "/Applications/V2Mac.app")
        let key = defaults.string(forKey: "debugAppUpdateKey").flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } ?? AppInstaller.updateKey
        let downloaded = Mutex<Int64>(0)
        do {
            let version = try BundleManifest(data: try await downloader.download(manifest)).version
            let prepared = try await AppInstaller.prepareDelta(
                manifest: manifest, expectedVersion: version, bundleIdentifier: "io.github.lordversa.v2mac", installed: installed,
                alternates: ["Contents/Helpers/xray": AppPaths.coreDirectory.appendingPathComponent("xray")],
                work: AppPaths.updatesDirectory.appendingPathComponent("building"), downloader: downloader,
                download: ResumableDownload(routes: downloadRoutes()), signedBy: key,
                onProgress: { p in downloaded.withLock { $0 = max($0, p.received) } }
            )
            print("[v2mac-debug] app update: built \(prepared.version) at \(prepared.app.path), downloaded \(downloaded.withLock { $0 }) bytes")
        } catch {
            print("[v2mac-debug] app update failed: \(error)")
        }
    }
    #endif

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
            // In the task, so it runs after AppModel has wired the notifications.
            let current = Prefs.appVersion, defaults = UserDefaults.standard
            if let last = defaults.string(forKey: "lastLaunchedVersion"), VersionCompare.isNewer(current, than: last) {
                self?.onFound(.updated(current))
            }
            defaults.set(current, forKey: "lastLaunchedVersion")
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.checkApp()
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

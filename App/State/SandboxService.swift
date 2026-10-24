import AppKit
import Observation
import V2MacCore

/// Spec 12.11: the only sandbox code in V2Mac. Downloads the pinned sandbox, checks it, launches the
/// helper with one end of a socketpair as fd 3 and talks to it over `SandboxLink`. Everything else
/// (the VM, the Sandbox window) is the helper's.
@MainActor @Observable
final class SandboxService {
    enum Phase: Equatable {
        case notInstalled
        case downloading(Double?)
        case installed
        case failed(String)
    }

    /// The one sandbox release this build accepts; nil hides the sandbox.
    let pin: SandboxPin? = SandboxService.loadPin()
    let files = SandboxFiles(root: AppPaths.dataDirectory.appendingPathComponent("sandbox", isDirectory: true))
    private(set) var phase = Phase.notInstalled
    /// The helper's VM: "stopped", "booting", "running" or "stopping".
    private(set) var vmState = "stopped"
    var isRunning: Bool { helper != nil }
    /// From a click that has to launch the helper until it says hello (its window opens right after).
    private(set) var isOpening = false
    var showEntrySheet = false

    var downloadRoutes: () -> [FetchRoute] = { [.direct] }
    var onNotice: (NotificationKind, String) -> Void = { _, _ in }
    /// The servers a mini VM can pick as its exit, and the active one's id.
    var serverList: () -> ([SandboxLink.Server], String?) = { ([], nil) }
    /// A server's ready outbound JSON (sandbox plan §4), or nil for one that can't be an exit.
    var outboundJSON: (String) async -> String? = { _ in nil }
    /// Debug hooks follow the link.
    var onEvent: (SandboxLink.ToApp) -> Void = { _ in }

    private var helper: pid_t?
    private var link: FileHandle?
    private var exitSource: DispatchSourceProcess?
    private var quitReply: CheckedContinuation<Bool, Never>?
    private var downloadTask: Task<Void, Never>?

    init() {
        if files.isInstalled { phase = .installed }
    }

    private static func loadPin() -> SandboxPin? {
        #if DEBUG
        // `-debugSandboxPin <pin.json>` (sandbox repo, Scripts/package.sh): a locally served sandbox.
        if let path = UserDefaults.standard.string(forKey: "debugSandboxPin"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return try? JSONDecoder().decode(SandboxPin.self, from: data)
        }
        #endif
        // shortcut: no sandbox release yet; the first locked release (sandbox plan M7) pins it here.
        return nil
    }

    // MARK: Entry

    /// The Sandbox button: opens the helper's window, or the entry sheet when nothing is installed.
    func open() {
        guard phase == .installed else { return showEntrySheet = true }
        do {
            if helper == nil { isOpening = true }
            try launchIfNeeded()
            send(.openWindow)
        } catch {
            isOpening = false
            phase = .failed(error.localizedDescription)
            showEntrySheet = true
        }
    }

    func download() {
        guard let pin, downloadTask == nil else { return }
        phase = .downloading(nil)
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try await ResumableDownload(routes: downloadRoutes()).fetch(pin.url, to: files.partial, expectedSize: pin.size) { progress in
                    Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(progress.fraction) } }
                }
                try await files.install(pin)
                phase = .installed
                onNotice(.sandboxReady, String(localized: "The Secure Sandbox is ready to open."))
            } catch is CancellationError {
                phase = .notInstalled
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    // MARK: Helper process

    private func launchIfNeeded() throws {
        guard helper == nil, let pin else { return }
        try files.verify(pin)
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        defer { close(fds[1]) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 3)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing else of V2Mac's leaks into the helper: every other descriptor closes on spawn.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let path = files.executable.path
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, &argv, environ)
        guard status == 0 else {
            close(fds[0])
            throw POSIXError(.init(rawValue: status) ?? .EIO)
        }
        helper = pid
        let link = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        self.link = link
        send(.hello(version: SandboxLink.version, ramCapMB: Prefs.sandboxRAMCapMB, core: AppPaths.coreExecutable.path))
        serversChanged()
        nonisolated(unsafe) var reader = SandboxLink.Reader<SandboxLink.ToApp>()
        link.readabilityHandler = { handle in
            let data = handle.availableData
            let messages = data.isEmpty ? nil : try? reader.feed(data)
            Task { @MainActor in
                guard let messages else {
                    handle.readabilityHandler = nil
                    return self.linkClosed()
                }
                messages.forEach(self.handle)
            }
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.helperExited() } }
        source.resume()
        exitSource = source
    }

    private func handle(_ message: SandboxLink.ToApp) {
        onEvent(message)
        switch message {
        case .hello(let version):
            isOpening = false
            if version != SandboxLink.version { linkClosed() }
        case .vmState(let state): vmState = state
        case .quitReply(let appsOpen):
            quitReply?.resume(returning: appsOpen)
            quitReply = nil
        case .notice(let kind, let text):
            // Only the sandbox's own kinds; the helper can't post as another part of V2Mac.
            if let kind = NotificationKind(rawValue: kind), kind.isSandbox { onNotice(kind, text) }
        case .outbound(let id):
            Task { send(.outbound(id: id, json: await outboundJSON(id))) }
        case .probe: break // debug hooks read it from onEvent
        case .download(let request, let url, let sha256):
            Task { send(.downloaded(request: request, path: await fetchLayer(url, sha256: sha256)?.path)) }
        case .fetch(let request, let url):
            Task { send(.downloaded(request: request, path: await fetchSmall(url, request: request)?.path)) }
        }
    }

    /// Largest plugin layer the helper may ask for.
    static let maxLayer: Int64 = 4 << 30

    /// A plugin layer for the helper (sandbox plan §7 "Install"): fetched through the usual routes into
    /// `sandbox/cache/<sha256>` and handed over only when its hash matches, so the route doesn't matter.
    private func fetchLayer(_ url: URL, sha256: String) async -> URL? {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), Self.allowed(url) else { return nil }
        let cache = files.root.appendingPathComponent("cache", isDirectory: true)
        let file = cache.appendingPathComponent(sha256)
        let partial = file.appendingPathExtension("part")
        let hash = { (f: URL) in await Task.detached { try? SandboxFiles.sha256(of: f) }.value }
        if await hash(file) == sha256 { return file }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        do {
            try await ResumableDownload(routes: downloadRoutes()).fetch(url, to: partial, expectedSize: Self.maxLayer)
        } catch {
            return nil
        }
        guard await hash(partial) == sha256 else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        try? FileManager.default.removeItem(at: file)
        return (try? FileManager.default.moveItem(at: partial, to: file)) != nil ? file : nil
    }

    /// The store index or its signature, fresh each time, into `sandbox/cache/fetch-<request>`.
    private func fetchSmall(_ url: URL, request: Int) async -> URL? {
        guard Self.allowed(url) else { return nil }
        let cache = files.root.appendingPathComponent("cache", isDirectory: true)
        let file = cache.appendingPathComponent("fetch-\(request)")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file) // a leftover would be resumed, not replaced
        do {
            try await ResumableDownload(routes: downloadRoutes()).fetch(url, to: file, expectedSize: Int64(SandboxLink.maxFetch))
            return file
        } catch {
            return nil
        }
    }

    /// https only; debug builds also take a store served on 127.0.0.1.
    private static func allowed(_ url: URL) -> Bool {
        #if DEBUG
        if url.scheme == "http", url.host == "127.0.0.1" { return true }
        #endif
        return url.scheme == "https"
    }

    private func send(_ message: SandboxLink.ToHelper) {
        guard let link, let data = try? SandboxLink.frame(message) else { return }
        try? link.write(contentsOf: data)
    }

    /// A broken or closed link: the helper must not run on without V2Mac.
    private func linkClosed() {
        link?.readabilityHandler = nil
        link = nil
        if let helper { kill(helper, SIGTERM) }
    }

    private func helperExited() {
        if let helper { waitpid(helper, nil, WNOHANG) }
        exitSource?.cancel()
        exitSource = nil
        helper = nil
        isOpening = false
        link?.readabilityHandler = nil
        link = nil
        vmState = "stopped"
        quitReply?.resume(returning: false)
        quitReply = nil
    }

    /// Sends the server list again; the helper then asks for every exit anew, so a changed server,
    /// TUN mode or network binding reaches the mini VMs without restarting them.
    func serversChanged() {
        let (servers, active) = serverList()
        send(.servers(servers, active: active))
    }

    /// Debug builds: the helper runs the leak probes and answers with `probe` (sandbox plan M2).
    func probe() { send(.probe) }

    func ramCapChanged() { send(.settings(ramCapMB: Prefs.sandboxRAMCapMB)) }

    // MARK: Quit and Remove

    /// Whether sandbox apps are open (asks the helper; no answer in 2 seconds counts as none).
    func appsOpen() async -> Bool {
        guard helper != nil else { return false }
        send(.quitRequest)
        return await withCheckedContinuation { continuation in
            quitReply?.resume(returning: false)
            quitReply = continuation
            Task {
                try? await Task.sleep(for: .seconds(2))
                quitReply?.resume(returning: false)
                quitReply = nil
            }
        }
    }

    /// Stops the helper and its VM; after 15 seconds it is killed.
    func stop() async {
        guard let pid = helper else { return }
        send(.quit)
        for _ in 0..<150 where helper != nil { try? await Task.sleep(for: .milliseconds(100)) }
        if helper != nil { kill(pid, SIGKILL) }
    }

    /// One confirm in Settings deletes helper, image, data disk and the generated apps.
    func remove() async {
        cancelDownload()
        await stop()
        let fm = FileManager.default
        try? fm.removeItem(at: files.root)
        try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/V2Mac Sandbox", isDirectory: true))
        phase = .notInstalled
    }

    /// Disk space the sandbox folder takes (the data disk is sparse, so its allocated size counts).
    func diskUsage() -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: files.root, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

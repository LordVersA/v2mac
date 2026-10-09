import AppKit
import Network

/// Reports wake-from-sleep and real network path changes, debounced (spec 9.3).
@MainActor
final class LifecycleMonitor {
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var debounce: Task<Void, Never>?
    private var lastSignature: String?
    private let onTrigger: @MainActor (String) -> Void
    /// Our own TUN interface: it coming or going is not a network change.
    private let ignoredInterface: @MainActor () -> String?

    init(ignoredInterface: @escaping @MainActor () -> String? = { nil }, onTrigger: @escaping @MainActor (String) -> Void) {
        self.ignoredInterface = ignoredInterface
        self.onTrigger = onTrigger
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule("wake from sleep") }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let status = "\(path.status)"
            let interfaces = path.availableInterfaces.map(\.name)
            let usable = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(status: status, interfaces: interfaces, usable: usable) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    private func pathChanged(status: String, interfaces: [String], usable: Bool) {
        let ignored = ignoredInterface()
        let signature = "\(status)-" + interfaces.filter { $0 != ignored }.sorted().joined(separator: ",")
        defer { lastSignature = signature }
        guard let last = lastSignature, last != signature, usable else { return }
        schedule("network change")
    }

    private func schedule(_ reason: String) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.onTrigger(reason)
        }
    }
}

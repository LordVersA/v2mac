import Darwin
import Foundation
import Network
import os
import SystemConfiguration

public enum NetworkInterfaces {
    /// The interface that carries the default route (`en0`, …), or nil when offline.
    /// `excluding` is our own TUN, which must never be picked as the way out.
    public static func primary(excluding: String? = nil) -> String? {
        for family in ["IPv4", "IPv6"] {
            let key = "State:/Network/Global/\(family)" as CFString
            guard let info = SCDynamicStoreCopyValue(nil, key) as? [String: Any],
                  let name = info["PrimaryInterface"] as? String, !name.isEmpty, name != excluding else { continue }
            return name
        }
        return nil
    }

    public static func exists(_ name: String) -> Bool {
        if_nametoindex(name) != 0
    }

    /// A `utunN` name nothing uses yet. The system takes the low numbers for itself.
    public static func freeUtunName() -> String {
        (100..<1000).lazy.map { "utun\($0)" }.first { !exists($0) } ?? "utun999"
    }

    /// The Network framework object for `name`, for pinning an `NWConnection` to it.
    public static func nwInterface(named name: String) async -> NWInterface? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "v2mac.interface-lookup")
        return await withCheckedContinuation { (continuation: CheckedContinuation<NWInterface?, Never>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ interface: NWInterface?) {
                let already = finished.withLock { done -> Bool in
                    let was = done
                    done = true
                    return was
                }
                guard !already else { return }
                monitor.cancel()
                continuation.resume(returning: interface)
            }
            monitor.pathUpdateHandler = { path in
                finish(path.availableInterfaces.first { $0.name == name })
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) { finish(nil) }
        }
    }
}

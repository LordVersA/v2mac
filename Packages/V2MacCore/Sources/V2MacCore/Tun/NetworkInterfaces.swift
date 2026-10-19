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

    /// The resolvers the system uses now, as addresses the core can dial on the physical
    /// interface: this Mac's own and link-local (`%en0`) ones are left out. With `interface`, the
    /// ones of that network, which can differ from the default network's.
    public static func dnsServers(on interface: String? = nil) -> [String] {
        var key = "State:/Network/Global/DNS"
        if let interface, interface != primary(), let service = serviceID(of: interface) { key = "State:/Network/Service/\(service)/DNS" }
        let info = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any]
        return ((info?["ServerAddresses"] as? [String]) ?? []).filter { address in
            !address.contains("%") && !ConfigBuilder.isLoopback(address) && (IPv4Address(address) != nil || IPv6Address(address) != nil)
        }
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

    /// The network service (`State:/Network/Service/<id>/…`) that runs on `interface`.
    static func serviceID(of interface: String) -> String? {
        let keys = SCDynamicStoreCopyKeyList(nil, "State:/Network/Service/[^/]+/IPv[46]" as CFString) as? [String] ?? []
        let key = keys.first { (SCDynamicStoreCopyValue(nil, $0 as CFString) as? [String: Any])?["InterfaceName"] as? String == interface }
        return key.map { $0.split(separator: "/")[3] }.map(String.init)
    }

    /// Networks the core's connections can leave through now (spec 8.4, Outgoing network): up,
    /// running and with an address that is not link-local. The default network comes first.
    public static func outgoing(excluding: String? = nil) -> [OutgoingNetwork] {
        var addresses: [String: [String]] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING) == IFF_UP | IFF_RUNNING, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, let text = numericHost(address),
                  !text.hasPrefix("169.254."), !text.lowercased().hasPrefix("fe80") else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if name != excluding { addresses[name, default: []].append(text) }
        }
        let primary = primary(excluding: excluding)
        return addresses.map { describe($0, addresses: $1) }
            .sorted { ($0.name == primary ? 0 : 1, $0.name) < ($1.name == primary ? 0 : 1, $1.name) }
    }

    /// What kind of network `name` is, also once it has gone (as far as macOS still knows it).
    public static func describe(_ name: String, addresses: [String] = []) -> OutgoingNetwork {
        let interface = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).first { SCNetworkInterfaceGetBSDName($0) as String? == name }
        let type = interface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
        let hardware = interface.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
        return OutgoingNetwork(name: name, kind: OutgoingNetwork.kind(name: name, type: type, hardware: hardware), hardware: hardware, addresses: addresses)
    }

    /// Whether `name` can carry connections now (see `outgoing`).
    public static func isConnected(_ name: String) -> Bool {
        outgoing().contains { $0.name == name }
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }
}

/// A network the user can pick for the core's connections.
public struct OutgoingNetwork: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case wifi, ethernet, iPhone, bluetooth, bridge, vpn, other }

    /// The BSD name the core binds to (`en0`).
    public var name: String
    public var kind: Kind
    /// What macOS calls the hardware (`USB 10/100/1000 LAN`), in the system's language.
    public var hardware: String?
    public var addresses: [String]
    public var id: String { name }

    /// `type` is the SystemConfiguration interface type (`kSCNetworkInterfaceType…`); tunnels
    /// of other VPN apps have none.
    static func kind(name: String, type: String?, hardware: String?) -> Kind {
        switch type {
        case "IEEE80211": return .wifi
        case "Bluetooth": return .bluetooth
        case "Bridge": return .bridge
        case "Ethernet":
            return ["iPhone", "iPad"].contains { hardware?.contains($0) == true } ? .iPhone : .ethernet
        default:
            return ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) } ? .vpn : .other
        }
    }
}

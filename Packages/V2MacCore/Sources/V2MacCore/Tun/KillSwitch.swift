import Darwin
import Foundation

/// Spec 9.8. The kill switch is a pf anchor the root helper loads while the app wants a
/// connection: everything that leaves this Mac is refused except loopback, the session's TUN,
/// the local network, DHCP, name lookups and the servers the core dials. It stays in place
/// while the core restarts or crashes and while the app is gone, until the user disconnects.
public enum KillSwitch {
    /// Present while the app wants the block in place.
    public static let flag = "killswitch.on"
    /// Addresses the core may reach directly, one per line. The helper takes only lines that
    /// look like an address, so this file cannot carry anything else into the firewall.
    public static let allowFile = "killswitch.allow"
    /// Why the last attempt to arm failed, in the helper's root directory.
    public static let errorFile = "killswitch.error"
    static let table = "v2mac_allow"

    /// The system's own `/etc/pf.conf` evaluates every anchor under `com.apple`, so a child
    /// anchor there needs no change to the main ruleset.
    public static func anchor(name: String) -> String { "com.apple/\(name)" }

    /// Holds pf's enable token while the block is armed. It lives outside the helper's root
    /// directory, so it outlives a helper that ended with the block still in place.
    public static func marker(name: String, uid: uid_t = getuid()) -> URL {
        URL(fileURLWithPath: "/var/run/\(name)-killswitch-\(uid)")
    }

    /// Stateless passes: nothing inbound is filtered, so replies need no state, and connections
    /// that were open before the block (to the server, or on loopback) keep working.
    public static func rules(tunInterface: String) -> String {
        """
        table <\(table)> persist
        pass quick on lo0 all flags any no state
        pass out quick on \(tunInterface) all flags any no state
        pass out quick inet proto udp from any port 68 to any port 67 no state
        pass out quick inet6 proto udp from any port 546 to any port 547 no state
        pass out quick proto { tcp, udp } from any to any port 53 flags any no state
        pass out quick inet from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 } flags any no state
        pass out quick inet6 from any to { fe80::/10, ff00::/8, fc00::/7 } flags any no state
        pass out quick from any to <\(table)> flags any no state
        block return out quick all
        """
    }

    /// The server addresses a profile's core dials directly: the outbound's, or for a full
    /// config every outbound's.
    public static func hosts(in config: JSONValue, kind: ProfileKind) -> [String] {
        let outbounds = kind == .custom ? (config["outbounds"]?.arrayValue ?? []) : [config]
        return Array(Set(outbounds.flatMap(ConfigBuilder.dialedHosts))).sorted()
    }

    /// What `hosts` resolve to now, IPv4 and IPv6; addresses are kept as they are.
    public static func addresses(of hosts: [String]) async -> [String] {
        await withTaskGroup(of: [String].self) { group in
            for host in hosts {
                group.addTask { await Task.detached { resolve(host) }.value }
            }
            var all = Set<String>()
            for await found in group { all.formUnion(found) }
            return all.sorted()
        }
    }

    static func resolve(_ host: String) -> [String] {
        let name = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var found: [String] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // A link-local answer carries its interface (`fe80::1%en0`), which pf does not take.
            let address = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            found.append(String(address.prefix { $0 != "%" }))
        }
        return found
    }
}

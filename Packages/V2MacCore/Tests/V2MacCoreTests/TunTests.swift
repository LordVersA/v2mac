import Foundation
import Testing
@testable import V2MacCore

@Suite struct TunConfigTests {
    let link = TunLink(port: 10891, outboundInterface: "en7")

    func options(tun: TunLink? = nil) -> RunOptions {
        RunOptions(metricsPort: 20000, tun: tun)
    }

    @Test func tunAddsLoopbackInboundAndBindsOutbounds() throws {
        let c = try ConfigBuilder.build(outbound: ["protocol": "vless"], options: options(tun: link), routing: .global)
        let inbound = c["inbounds"]?[1]
        #expect(inbound?["tag"]?.stringValue == "tun-in")
        #expect(inbound?["listen"]?.stringValue == "127.0.0.1")
        #expect(inbound?["port"]?.intValue == 10891)
        #expect(inbound?["protocol"]?.stringValue == "socks")
        #expect(inbound?["settings"]?["udp"]?.boolValue == true)
        #expect(c["outbounds"]?[0]?["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en7")
        #expect(c["outbounds"]?[1]?["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en7")
        #expect(c["outbounds"]?[2]?["streamSettings"] == nil)
    }

    @Test func withoutTunNothingChanges() throws {
        let c = try ConfigBuilder.build(outbound: ["protocol": "vless"], options: options(), routing: .global)
        #expect(c["inbounds"]?[1] == nil)
        #expect(c["outbounds"]?[0]?["streamSettings"] == nil)
        #expect(c["outbounds"]?[1]?["streamSettings"] == nil)
    }

    @Test func tunSkipsAppRulesButKeepsHostRules() throws {
        let custom = CustomRules(rules: [
            CustomRule(name: "App", action: .block, apps: "curl"),
            CustomRule(name: "Both", action: .direct, apps: "curl", hosts: "example.com"),
            CustomRule(name: "Host", action: .block, hosts: "example.org"),
        ])
        for tun in [nil, link] {
            let config = try ConfigBuilder.build(outbound: ["protocol": "vless"], options: options(tun: tun), routing: .global, custom: custom)
            let rules = try #require(config["routing"]?["rules"]?.arrayValue)
            let appRules = rules.filter { $0["process"] != nil }
            #expect(appRules.count == 2)
            for rule in appRules {
                #expect(rule["process"] == ["curl"])
                #expect(rule["inboundTag"] == (tun == nil ? nil : ["mixed-in"]))
            }
            #expect(appRules[1]["domain"] == ["domain:example.com"])
            #expect(rules.contains { $0["domain"] == ["domain:example.org"] && $0["inboundTag"] == nil })
        }
    }

    @Test func tunExcludesItselfFromImportedProcessRules() throws {
        let imported: JSONValue = [
            "inbounds": [["tag": "socks", "protocol": "socks"]],
            "outbounds": [["tag": "direct", "protocol": "freedom"]],
            "routing": ["rules": [
                ["type": "field", "process": ["curl"], "outboundTag": "direct"],
                ["type": "field", "process": ["git"], "inboundTag": ["socks"], "outboundTag": "direct"],
                ["type": "field", "process": ["xray"], "inboundTag": ["tun-in"], "outboundTag": "direct"],
                ["type": "field", "domain": ["domain:example.org"], "inboundTag": ["socks"], "outboundTag": "direct"],
            ]],
        ]
        let config = try ConfigBuilder.buildCustom(config: imported, options: options(tun: link))
        let rules = try #require(config["routing"]?["rules"]?.arrayValue)
        let appRules = rules.filter { $0["process"] != nil }
        #expect(appRules.count == 2)
        #expect(appRules.map { $0["process"] } == [["curl"], ["git"]])
        #expect(appRules.allSatisfy { $0["inboundTag"] == ["mixed-in"] })
        #expect(rules.contains { $0["domain"] == ["domain:example.org"] && $0["inboundTag"] == ["mixed-in", "tun-in"] })
    }

    @Test func bindingKeepsExistingStreamSettings() {
        let outbound: JSONValue = ["protocol": "vless", "streamSettings": ["network": "ws", "sockopt": ["mark": 5]]]
        let bound = ConfigBuilder.binding(outbound, to: "en7")
        #expect(bound["streamSettings"]?["network"]?.stringValue == "ws")
        #expect(bound["streamSettings"]?["sockopt"]?["mark"]?.intValue == 5)
        #expect(bound["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en7")
    }

    @Test func bindingLeavesOutboundsThatMustNotBeBound() {
        let chosen: JSONValue = ["protocol": "freedom", "streamSettings": ["sockopt": ["interface": "en3"]]]
        #expect(ConfigBuilder.binding(chosen, to: "en7") == chosen)
        for name in ["blackhole", "dns", "loopback"] {
            let outbound: JSONValue = ["protocol": .string(name)]
            #expect(ConfigBuilder.binding(outbound, to: "en7") == outbound)
        }
        let local: JSONValue = ["protocol": "socks", "settings": ["servers": [["address": "127.0.0.1", "port": 9050]]]]
        #expect(ConfigBuilder.binding(local, to: "en7") == local)
        let flat: JSONValue = ["protocol": "socks", "settings": ["address": "localhost", "port": 9050]]
        #expect(ConfigBuilder.binding(flat, to: "en7") == flat)
    }

    @Test func customConfigBindsEveryOutboundAndRoutesTunLikeItsProxyInbound() throws {
        let custom: JSONValue = [
            "inbounds": [["tag": "socks", "protocol": "socks", "port": 1080]],
            "outbounds": [
                ["tag": "a", "protocol": "vless", "settings": ["vnext": [["address": "example.com", "port": 443]]]],
                ["tag": "b", "protocol": "freedom"],
                ["tag": "c", "protocol": "blackhole"],
            ],
            "routing": ["rules": [["type": "field", "inboundTag": ["socks"], "outboundTag": "a"]]],
        ]
        let c = try ConfigBuilder.buildCustom(config: custom, options: options(tun: link))
        #expect(c["inbounds"]?.arrayValue?.count == 2)
        #expect(c["outbounds"]?[0]?["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en7")
        #expect(c["outbounds"]?[1]?["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en7")
        #expect(c["outbounds"]?[2]?["streamSettings"] == nil)
        // After the two DNS rules of TUN mode.
        #expect(c["routing"]?["rules"]?[2]?["inboundTag"] == ["mixed-in", "tun-in"])

        let plain = try ConfigBuilder.buildCustom(config: custom, options: options())
        #expect(plain["routing"]?["rules"]?[0]?["inboundTag"] == ["mixed-in"])
        #expect(plain["outbounds"]?[0]?["streamSettings"] == nil)
    }

    @Test func forwarderCarriesOnlyTheTunAndTheCorePort() {
        let c = ConfigBuilder.tunForwarder(interfaceName: "utun123", corePort: 10891)
        #expect(c["inbounds"]?.arrayValue?.count == 1)
        let settings = c["inbounds"]?[0]?["settings"]
        #expect(c["inbounds"]?[0]?["protocol"]?.stringValue == "tun")
        #expect(settings?["name"]?.stringValue == "utun123")
        #expect(settings?["autoSystemRoutingTable"] == ["0.0.0.0/0", "::/0"])
        #expect(settings?["autoOutboundsInterface"]?.stringValue == "auto")
        #expect(c["inbounds"]?[0]?["sniffing"]?["routeOnly"] == nil)
        #expect(c["outbounds"]?[0]?["protocol"]?.stringValue == "socks")
        #expect(c["outbounds"]?[0]?["settings"]?["address"]?.stringValue == "127.0.0.1")
        #expect(c["outbounds"]?[0]?["settings"]?["port"]?.intValue == 10891)
        // Nothing, DNS included, may leave the forwarder any other way than through the core.
        #expect(c["outbounds"]?.arrayValue?.count == 1)
        #expect(c["routing"] == nil)
    }

    // MARK: DNS in TUN mode (spec 9.5)

    func tunLink(_ resolvers: [String] = ["192.168.1.1"]) -> TunLink {
        TunLink(port: 10891, outboundInterface: "en7", resolvers: resolvers)
    }

    let named: JSONValue = ["protocol": "vless", "settings": ["vnext": [["address": "server.example.com", "port": 443]]]]

    func outbound(_ config: JSONValue, _ tag: String) -> JSONValue? {
        config["outbounds"]?.arrayValue?.first { $0["tag"]?.stringValue == tag }
    }

    @Test func everyLookupFromTheTunIsAnsweredByTheCore() throws {
        let c = try ConfigBuilder.build(outbound: named, options: options(tun: tunLink()), routing: .global)
        let rules = try #require(c["routing"]?["rules"]?.arrayValue)
        // First: the core's own lookups of the server's name; then every DNS query from the TUN,
        // whatever resolver it was sent to (a private one would otherwise match `geoip:private`).
        #expect(rules[0] == ["type": "field", "inboundTag": ["v2mac-bootstrap-dns"], "outboundTag": "v2mac-bootstrap"])
        #expect(rules[1] == ["type": "field", "inboundTag": ["tun-in"], "port": "53", "outboundTag": "v2mac-dns-out"])
        #expect(outbound(c, "v2mac-dns-out")?["protocol"]?.stringValue == "dns")
        #expect(outbound(c, "v2mac-dns-out")?["settings"] == nil, "A and AAAA go to the core's resolver, other types get an empty answer")

        // The core's resolver asks through the proxy, except for the server's own name.
        let servers = try #require(c["dns"]?["servers"]?.arrayValue)
        #expect(servers[0] == ["address": "192.168.1.1", "domains": ["full:server.example.com"], "skipFallback": true, "tag": "v2mac-bootstrap-dns"])
        #expect(Array(servers.dropFirst()) == ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"])
        #expect(outbound(c, "v2mac-bootstrap")?["protocol"]?.stringValue == "freedom")
        #expect(outbound(c, "v2mac-bootstrap")?["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en7")

        // The server's name is resolved by the core, not by the system resolver (which is the TUN).
        let proxy = try #require(outbound(c, "proxy"))
        #expect(proxy["streamSettings"]?["sockopt"]?["domainStrategy"]?.stringValue == "UseIPv4v6")
        #expect(proxy["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en7")
        #expect(outbound(c, "direct")?["streamSettings"]?["sockopt"]?["domainStrategy"] == nil)
    }

    @Test func serverByAddressNeedsNoLookupOfItsOwn() throws {
        let byIP: JSONValue = ["protocol": "trojan", "settings": ["servers": [["address": "203.0.113.5", "port": 443]]]]
        let c = try ConfigBuilder.build(outbound: byIP, options: options(tun: tunLink()), routing: .global)
        #expect(c["routing"]?["rules"]?[0]?["outboundTag"]?.stringValue == "v2mac-dns-out")
        #expect(outbound(c, "v2mac-bootstrap") == nil)
        #expect(c["dns"]?["servers"] == ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"])
        #expect(outbound(c, "proxy")?["streamSettings"]?["sockopt"]?["domainStrategy"] == nil)
    }

    @Test func theUsersResolversAndModesAreKept() throws {
        var o = options(tun: tunLink())
        o.dns = DNSSettings(servers: ["localhost", "https://9.9.9.9/dns-query"], queryStrategy: .useIPv4)
        let c = try ConfigBuilder.build(outbound: named, options: o, routing: .global)
        // `localhost` is the system resolver, which is the TUN: it would ask itself.
        #expect(c["dns"]?["servers"]?.arrayValue?.dropFirst().map { $0 } == ["https://9.9.9.9/dns-query"])
        #expect(c["dns"]?["queryStrategy"]?.stringValue == "UseIPv4")

        let route = RegionRoute(geositeFile: "ir.dat", geositeTags: ["ir"], geoipFile: "irip.dat", geoipTags: ["ir"])
        let bypass = try ConfigBuilder.build(outbound: named, options: options(tun: tunLink()), routing: .bypass([route]))
        #expect(bypass["routing"]?["domainStrategy"]?.stringValue == "IPIfNonMatch")
        #expect(bypass["routing"]?["rules"]?[1]?["outboundTag"]?.stringValue == "v2mac-dns-out")
        #expect(bypass["dns"]?["servers"]?.arrayValue?.count == 3)

        let direct = try ConfigBuilder.build(outbound: named, options: options(tun: tunLink()), routing: .direct)
        #expect(direct["routing"]?["rules"]?[1]?["outboundTag"]?.stringValue == "v2mac-dns-out")
    }

    @Test func theDialerResolvesTheNameItDialsForTheProxy() throws {
        var o = options(tun: tunLink())
        o.dialer = DialerSettings(fragment: FragmentSettings())
        let c = try ConfigBuilder.build(outbound: named, options: o, routing: .global)
        #expect(outbound(c, "v2mac-dialer")?["streamSettings"]?["sockopt"]?["domainStrategy"]?.stringValue == "UseIPv4v6")
        #expect(outbound(c, "v2mac-dialer")?["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en7")
    }

    @Test func customConfigsGetTheSameDNS() throws {
        let custom: JSONValue = [
            "inbounds": [["tag": "socks", "protocol": "socks", "port": 1080]],
            "outbounds": [
                ["tag": "a", "protocol": "vless", "settings": ["vnext": [["address": "one.example.com", "port": 443]]],
                 "streamSettings": ["sockopt": ["dialerProxy": "frag"]]],
                ["tag": "b", "protocol": "trojan", "settings": ["servers": [["address": "two.example.com", "port": 443]]]],
                ["tag": "frag", "protocol": "freedom", "settings": ["fragment": ["packets": "tlshello"]]],
            ],
            "dns": ["servers": ["localhost"], "tag": "their-dns"],
        ]
        let c = try ConfigBuilder.buildCustom(config: custom, options: options(tun: tunLink(["192.168.1.1", "fd00::1"])))
        let servers = try #require(c["dns"]?["servers"]?.arrayValue)
        #expect(servers.count == 4)
        #expect(servers[0]["domains"] == ["full:one.example.com", "full:two.example.com"])
        #expect(servers[1]["address"]?.stringValue == "fd00::1")
        #expect(Array(servers.dropFirst(2)) == ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"])
        #expect(c["dns"]?["tag"]?.stringValue == "their-dns")
        for tag in ["a", "b", "frag"] {
            #expect(outbound(c, tag)?["streamSettings"]?["sockopt"]?["domainStrategy"]?.stringValue == "UseIPv4v6", "\(tag)")
        }
        #expect(c["routing"]?["rules"]?[1]?["outboundTag"]?.stringValue == "v2mac-dns-out")
    }

    @Test func wireGuardPeersAndOddAddressesAreRead() {
        let wg: JSONValue = ["protocol": "wireguard", "settings": ["peers": [["endpoint": "wg.example.com:51820"], ["endpoint": "[2001:db8::1]:51820"]]]]
        #expect(ConfigBuilder.dialedNames(wg) == ["wg.example.com"])
        let local: JSONValue = ["protocol": "socks", "settings": ["address": "localhost", "port": 1]]
        #expect(ConfigBuilder.dialedNames(local).isEmpty)
        #expect(ConfigBuilder.dialedNames(["protocol": "freedom"]).isEmpty)
        let set: JSONValue = ["protocol": "vless", "streamSettings": ["sockopt": ["domainStrategy": "ForceIPv4"]], "settings": ["address": "x.example.com"]]
        #expect(ConfigBuilder.resolvingWithCore(set) == set, "a strategy the config chose is kept")
    }

    @Test func withoutTunDNSIsUntouched() throws {
        let c = try ConfigBuilder.build(outbound: named, options: options(), routing: .global)
        #expect(c["dns"] == nil)
        #expect(outbound(c, "v2mac-dns-out") == nil)
        #expect(outbound(c, "proxy")?["streamSettings"] == nil)
    }

    @Test func emptyResolverListFallsBack() {
        #expect(TunLink(port: 1, outboundInterface: "en0").resolvers == TunLink.fallbackResolvers)
        #expect(NetworkInterfaces.dnsServers().allSatisfy { !$0.contains("%") && !$0.hasPrefix("127.") })
    }

    @Test func statsSumBothTrafficInbounds() throws {
        let json = #"{"stats":{"inbound":{"mixed-in":{"downlink":100,"uplink":10},"tun-in":{"downlink":900,"uplink":90}}}}"#
        let s = try StatsClient.parse(Data(json.utf8), inboundTags: ConfigBuilder.trafficInboundTags)
        #expect(s.downlink == 1000)
        #expect(s.uplink == 100)
    }

    @Test func latencyBatchBindsWhenAsked() {
        let bound = LatencyConfig.batch(outbounds: [["protocol": "vless"]], ports: [1], interface: "en7")
        #expect(bound["outbounds"]?[0]?["streamSettings"]?["sockopt"]?["interface"]?.stringValue == "en7")
        let plain = LatencyConfig.batch(outbounds: [["protocol": "vless"]], ports: [1])
        #expect(plain["outbounds"]?[0]?["streamSettings"] == nil)
    }
}

@Suite struct TunHelperTests {
    @Test func launchCommandCarriesScriptAndConfigInline() throws {
        let command = TunHelper.launchCommand(
            appPID: 42, stateDirectory: URL(fileURLWithPath: "/it's/run"), core: URL(fileURLWithPath: "/x/xray"),
            coreSHA256: "abc", config: #"{"a":1}"#, rootDirectory: URL(fileURLWithPath: "/var/run/v2mac-tun-501"),
            killSwitchRules: "block all", killSwitchAnchor: "com.apple/v2mac", killSwitchMarker: URL(fileURLWithPath: "/var/run/v2mac-killswitch-501")
        )
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.hasSuffix(#" 'v2mac-tun-helper' '42' '/it'\''s/run' '/x/xray' 'abc' '{"a":1}' '/var/run/v2mac-tun-501' 'block all' 'com.apple/v2mac' '/var/run/v2mac-killswitch-501' > /dev/null 2>&1 &"#))
        #expect(command.range(of: #"\.sh['\s]"#, options: .regularExpression) == nil, "no script file a user process could change")
    }

    @Test func appleScriptEscapesQuotesAndBackslashes() {
        let script = TunHelper.appleScript(command: #"echo "a\b""#, prompt: "Allow?")
        #expect(script == #"do shell script "echo \"a\\b\"" with prompt "Allow?" with administrator privileges"#)
        #expect(!script.contains("user name"))
        #expect(!script.contains("password"))
    }

    @Test func rootDirectoryIsPerUserAndPerApp() {
        #expect(TunHelper.rootDirectory(uid: 501).path == "/var/run/v2mac-tun-501")
        #expect(TunHelper.rootDirectory(name: "v2mac-dev", uid: 501).path == "/var/run/v2mac-dev-tun-501")
        #expect(KillSwitch.marker(name: "v2mac", uid: 501).path == "/var/run/v2mac-killswitch-501")
    }

    @Test func helperWithoutPidFileIsNotAlive() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!TunHelper.isAlive(rootDirectory: dir))
        try "999999".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        #expect(!TunHelper.isAlive(rootDirectory: dir))
        try "\(getpid())\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        #expect(TunHelper.isAlive(rootDirectory: dir))
    }

    @Test func primaryInterfaceIsNeverTheExcludedOne() {
        guard let primary = NetworkInterfaces.primary() else { return } // offline machine
        #expect(NetworkInterfaces.exists(primary))
        #expect(NetworkInterfaces.primary(excluding: primary) != primary)
        #expect(!NetworkInterfaces.exists(NetworkInterfaces.freeUtunName()))
    }
}

/// Runs the real helper script without root, against a stand-in for the core.
@Suite(.serialized) struct TunHelperScriptTests {
    struct Session {
        let dir: URL
        let state: URL
        let root: URL
        let marker: URL
        let helper: Process
        let app: Process

        var flag: URL { state.appendingPathComponent(TunHelper.onFlag) }
        var session: URL { state.appendingPathComponent(TunHelper.sessionFlag) }
        var childRunning: Bool { FileManager.default.fileExists(atPath: marker.path) }
        /// The kill switch's marker, which holds pf's token while the block is armed.
        var ksMarker: URL { dir.appendingPathComponent("ks-marker") }
        /// What the stand-ins for `pfctl` and `networksetup` were asked, one call per line.
        var calls: [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func cleanUp() {
            if helper.isRunning { helper.terminate() }
            if app.isRunning { app.terminate() }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// `core` is the body of the stand-in core script; `$MARKER` names a file it may use.
    /// `hash` replaces the core's real SHA-256.
    /// `store` gives the helper a stand-in dynamic store in `dir/store`, whose primary service
    /// `A` has DNS `192.168.1.1`.
    /// `anchors: false` makes the stand-in `pfctl` report a main ruleset without Apple's anchors.
    func start(core: String, hash: String? = nil, store: Bool = false, anchors: Bool = true) async throws -> Session {
        let fm = FileManager.default
        let dir = try TestSupport.makeTempDirectory()
        let storeDir = dir.appendingPathComponent("store")
        if store {
            try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
            try "A".write(to: storeDir.appendingPathComponent("State__Network_Global_IPv4"), atomically: true, encoding: .utf8)
            for name in ["Setup__Network_Service_A_DNS", "_NetworkServices_A_DNS"] {
                try "192.168.1.1".write(to: storeDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        let state = dir.appendingPathComponent("state")
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let root = dir.appendingPathComponent("root")
        let marker = dir.appendingPathComponent("running")

        let fake = dir.appendingPathComponent("fake-core")
        try "#!/bin/sh\nMARKER='\(marker.path)'\n\(core)\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        fm.createFile(atPath: state.appendingPathComponent(TunHelper.sessionFlag).path, contents: nil)

        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["60"]
        try app.run()

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        let sha = try await TunHelper.sha256(of: fake)
        helper.arguments = ["-c", (store ? Self.fakeStore(storeDir) : Self.noSystemChanges) + Self.fakeFirewall(dir, anchors: anchors) + TunHelper.script,
                            "v2mac-tun-helper", "\(app.processIdentifier)", state.path, fake.path,
                            hash ?? sha, #"{"log":{}}"#, root.path, KillSwitch.rules(tunInterface: "utun123"), "com.apple/v2mac-test",
                            dir.appendingPathComponent("ks-marker").path]
        try helper.run()
        return Session(dir: dir, state: state, root: root, marker: marker, helper: helper, app: app)
    }

    let liveCore = "trap 'rm -f \"$MARKER\"; exit 0' TERM\ntouch \"$MARKER\"\nwhile :; do sleep 0.1; done"

    /// Shell functions take the place of the commands that change this Mac's DNS settings.
    static let noSystemChanges = "scutil() { cat > /dev/null; }\ndscacheutil() { :; }\nkillall() { :; }\n"

    /// Stand-ins for `pfctl` and `networksetup` that write each call to `dir/calls`. There are two
    /// network services with a device, one disabled and one without a device (a VPN).
    static func fakeFirewall(_ dir: URL, anchors: Bool) -> String {
        """
        CALLS='\(dir.appendingPathComponent("calls").path)'
        pfctl() {
          echo "pfctl $*" >> "$CALLS"
          case "$*" in
            "-s rules") \(anchors ? #"echo 'anchor "com.apple/*" all'"# : ":") ;;
            -E) echo 'pf enabled'; echo 'Token : 42' ;;
          esac
          return 0
        }
        networksetup() {
          echo "networksetup $*" >> "$CALLS"
          [ "$1" = -listnetworkserviceorder ] && printf '%s\\n' 'An asterisk (*) denotes that a network service is disabled.' \\
            '(1) Wi-Fi' '(Hardware Port: Wi-Fi, Device: en0)' '' '(2) VPN (Work)' '(Hardware Port: com.example.vpn, Device: )' '' \\
            '(*) Bluetooth PAN' '(Hardware Port: Bluetooth PAN, Device: en9)' '' '(3) USB 10/100 LAN' '(Hardware Port: USB 10/100 LAN, Device: en7)'
          return 0
        }

        """
    }

    /// A stand-in for `scutil` that keeps each key of the dynamic store, and with `--prefs` each
    /// path of the saved settings, in a file: a list of `ServerAddresses`, or for `…/IPv4` the
    /// primary service.
    static func fakeStore(_ dir: URL) -> String {
        """
        set -f
        STORE='\(dir.path)'
        key() { printf '%s/%s' "$STORE" "$(printf '%s' "$1" | tr '/:' '__')"; }
        val() { if [ -f "$(key "$1")" ]; then cat "$(key "$1")"; else printf absent; fi; }
        scutil() {
          sa=""
          while IFS= read -r line; do
            set -- $line
            f=$(key "${2:-}")
            case "$1" in
              show)
                if [ "${2%/IPv4}" != "$2" ]; then
                  if [ -f "$f" ]; then printf '<dictionary> {\n  PrimaryService : %s\n}\n' "$(cat "$f")"; else echo '  No such key'; fi
                elif [ -f "$f" ]; then
                  sa=$(cat "$f"); echo '<dictionary> {'
                  if [ -n "$sa" ]; then echo '  ServerAddresses : <array> {'; i=0; for a in $sa; do echo "    $i : $a"; i=$((i + 1)); done; echo '  }'; fi
                  echo '}'
                else
                  echo '  No such key'
                fi ;;
              d.show)
                echo '<dictionary> {'
                if [ -n "$sa" ]; then echo '  ServerAddresses : <array> {'; i=0; for a in $sa; do echo "    $i : $a"; i=$((i + 1)); done; echo '  }'; fi
                echo '}' ;;
              d.init) sa="" ;;
              get) if [ -f "$f" ]; then sa=$(cat "$f"); else echo '  No such key'; fi ;;
              d.add) shift 3; sa="$*" ;;
              d.remove) sa="" ;;
              set) printf '%s' "$sa" > "$f" ;;
              remove) rm -f "$f" ;;
            esac
          done
        }
        dscacheutil() { :; }
        killall() { echo x >> "$STORE/flushes"; }

        """
    }

    @Test func dnsIsPointedIntoTheTunAndPutBack() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let steps = #"""
        A=Setup:/Network/Service/A/DNS; B=Setup:/Network/Service/B/DNS
        printf A > "$(key State:/Network/Global/IPv4)"
        printf '172.19.0.2 1.1.1.1' > "$(key /NetworkServices/A/DNS)"; printf '172.19.0.2 1.1.1.1' > "$(key $A)"
        dns_apply; echo "1:$(val $A)"
        dns_apply; echo "2:$(val $A)"
        printf '9.9.9.9' > "$(key /NetworkServices/A/DNS)"; printf '9.9.9.9' > "$(key $A)"
        dns_apply; echo "3:$(val $A)"
        printf B > "$(key State:/Network/Global/IPv4)"
        dns_apply; echo "4:$(val $A)|$(val $B)"
        dns_restore; echo "5:$(val $B)"
        : > "$(key /NetworkServices/B/DNS)"; : > "$(key $B)"
        dns_apply; echo "6:$(val $B)"; dns_restore; echo "7:[$(val $B)]"
        dns_restore; echo "8:[$(val $B)]"
        printf A > "$(key State:/Network/Global/IPv4)"; printf '1.1.1.1 8.8.8.8' > "$(key $A)"
        dns_apply; dns_restore; echo "9:$(val $A)"
        rm "$(key State:/Network/Global/IPv4)"
        dns_apply; echo "10:$(val $A)"
        """#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.fakeStore(dir) + TunHelper.dnsFunctions + "\n" + steps]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(out.split(separator: "\n").map(String.init) == [
            "1:1.1.1.1 8.8.8.8",
            "2:1.1.1.1 8.8.8.8",
            // Changed in System Settings meanwhile: applied over again.
            "3:1.1.1.1 8.8.8.8",
            // Another service became primary: the first gets its saved settings back.
            "4:9.9.9.9|1.1.1.1 8.8.8.8",
            // Its saved settings have no DNS entry, so none is left behind.
            "5:absent",
            "6:1.1.1.1 8.8.8.8",
            "7:[]",
            "8:[]",
            // A helper killed earlier left its servers behind; the saved settings still know better.
            "9:9.9.9.9",
            // Offline: nothing to change.
            "10:9.9.9.9",
        ])
        let flushes = (try? String(contentsOf: dir.appendingPathComponent("flushes"), encoding: .utf8)) ?? ""
        #expect(flushes.split(separator: "\n").count == 9, "the cache is flushed after every change")
    }

    @Test func dnsIsPutBackWhenTheTunStopsOrTheAppDies() async throws {
        let s = try await start(core: liveCore, store: true)
        defer { s.cleanUp() }
        let fm = FileManager.default
        let setup = s.dir.appendingPathComponent("store/Setup__Network_Service_A_DNS")
        func value() -> String? { try? String(contentsOf: setup, encoding: .utf8) }
        #expect(value() == "192.168.1.1")

        fm.createFile(atPath: s.flag.path, contents: nil)
        #expect(await wait { value() == TunHelper.dnsServers })
        try fm.removeItem(at: s.flag)
        #expect(await wait { value() == "192.168.1.1" })

        fm.createFile(atPath: s.flag.path, contents: nil)
        #expect(await wait { value() == TunHelper.dnsServers })
        s.app.terminate()
        #expect(await wait { !s.helper.isRunning })
        #expect(value() == "192.168.1.1")
    }

    func wait(_ seconds: Double = 5, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func followsTheFlagAndEndsWithTheSession() async throws {
        let s = try await start(core: liveCore)
        defer { s.cleanUp() }
        let fm = FileManager.default

        #expect(await wait { TunHelper.isAlive(rootDirectory: s.root) })
        #expect(fm.isExecutableFile(atPath: s.root.appendingPathComponent("xray").path))
        #expect(try String(contentsOf: s.root.appendingPathComponent("config.json"), encoding: .utf8) == "{\"log\":{}}\n")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(!s.childRunning, "the core must not start before the flag is set")

        fm.createFile(atPath: s.flag.path, contents: nil)
        #expect(await wait { s.childRunning })
        try fm.removeItem(at: s.flag)
        #expect(await wait { !s.childRunning })
        #expect(s.helper.isRunning)

        fm.createFile(atPath: s.flag.path, contents: nil)
        #expect(await wait { s.childRunning })
        try fm.removeItem(at: s.session)
        #expect(await wait { !s.helper.isRunning })
        #expect(!s.childRunning)
        #expect(!fm.fileExists(atPath: s.root.path))
    }

    /// The whole command, script included, survives AppleScript quoting (run without the prompt).
    @Test func launchesThroughOsascript() async throws {
        let fm = FileManager.default
        let dir = try TestSupport.makeTempDirectory()
        defer { try? fm.removeItem(at: dir) }
        let state = dir.appendingPathComponent("state")
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let root = dir.appendingPathComponent("root")
        let fake = dir.appendingPathComponent("fake-core")
        try "#!/bin/sh\nwhile :; do sleep 0.1; done\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        fm.createFile(atPath: state.appendingPathComponent(TunHelper.sessionFlag).path, contents: nil)

        let command = TunHelper.launchCommand(
            appPID: getpid(), stateDirectory: state, core: fake, coreSHA256: try await TunHelper.sha256(of: fake),
            config: #"{"it's": "quoted \\ text"}"#, rootDirectory: root,
            killSwitchRules: KillSwitch.rules(tunInterface: "utun123"), killSwitchAnchor: "com.apple/v2mac-test",
            killSwitchMarker: dir.appendingPathComponent("ks-marker")
        )
        let source = TunHelper.appleScript(command: command, prompt: "unused")
            .replacingOccurrences(of: " with administrator privileges", with: "")
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", source]
        try osascript.run()
        osascript.waitUntilExit()
        #expect(osascript.terminationStatus == 0)
        #expect(await wait { TunHelper.isAlive(rootDirectory: root) })
        #expect(try String(contentsOf: root.appendingPathComponent("config.json"), encoding: .utf8) == #"{"it's": "quoted \\ text"}"# + "\n")
        try fm.removeItem(at: state.appendingPathComponent(TunHelper.sessionFlag))
        #expect(await wait { !fm.fileExists(atPath: root.path) })
    }

    func write(_ text: String, to name: String, in s: Session) throws {
        try text.write(to: s.state.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func killSwitchArmsTakesOnlyAddressesAndLiftsWhenAsked() async throws {
        let s = try await start(core: liveCore)
        defer { s.cleanUp() }
        let fm = FileManager.default
        #expect(await wait { TunHelper.isAlive(rootDirectory: s.root) })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!s.calls.contains { $0.hasPrefix("pfctl") }, "nothing is armed before the app asks")

        try write("1.2.3.4\nevil; rm -rf /\n2606:4700::1\n0.0.0.0/0\n", to: KillSwitch.allowFile, in: s)
        try write("", to: KillSwitch.flag, in: s)
        #expect(await wait { (try? String(contentsOf: s.ksMarker, encoding: .utf8)) == "42\n" })
        #expect(s.calls.contains("pfctl -a com.apple/v2mac-test -f \(s.root.path)/pf.rules"))
        #expect(try String(contentsOf: s.root.appendingPathComponent("pf.rules"), encoding: .utf8) == KillSwitch.rules(tunInterface: "utun123") + "\n")
        let allow = s.root.appendingPathComponent("allow")
        #expect(await wait { s.calls.contains("pfctl -a com.apple/v2mac-test -t v2mac_allow -T replace -f \(allow.path)") })
        #expect(try String(contentsOf: allow, encoding: .utf8) == "1.2.3.4\n2606:4700::1\n")
        #expect((try fm.attributesOfItem(atPath: allow.path)[.posixPermissions] as? Int) == 0o600)

        // A new server's address replaces the table again.
        try write("1.2.3.4\n5.6.7.8\n", to: KillSwitch.allowFile, in: s)
        #expect(await wait { (try? String(contentsOf: allow, encoding: .utf8)) == "1.2.3.4\n5.6.7.8\n" })

        try fm.removeItem(at: s.state.appendingPathComponent(KillSwitch.flag))
        #expect(await wait { !fm.fileExists(atPath: s.ksMarker.path) })
        #expect(s.calls.contains("pfctl -X 42"))
        #expect(s.calls.contains("pfctl -a com.apple/v2mac-test -F rules"))
        #expect(!s.calls.contains("pfctl -a com.apple/v2mac-test -F all"), "flushing all would clear pf's states for everyone")
        #expect(s.helper.isRunning)
    }

    @Test func killSwitchOutlivesACrashedAppButNotAQuit() async throws {
        let fm = FileManager.default
        let crashed = try await start(core: liveCore)
        defer { crashed.cleanUp() }
        try write("", to: KillSwitch.flag, in: crashed)
        #expect(await wait { fm.fileExists(atPath: crashed.ksMarker.path) })
        crashed.app.terminate()
        #expect(await wait { !crashed.helper.isRunning })
        #expect(fm.fileExists(atPath: crashed.ksMarker.path), "the block stays when the app dies with it on")
        #expect(!crashed.calls.contains("pfctl -X 42"))

        let quit = try await start(core: liveCore)
        defer { quit.cleanUp() }
        try write("", to: KillSwitch.flag, in: quit)
        #expect(await wait { fm.fileExists(atPath: quit.ksMarker.path) })
        // Quitting: the app takes its flag away, then ends the session.
        try fm.removeItem(at: quit.state.appendingPathComponent(KillSwitch.flag))
        try fm.removeItem(at: quit.session)
        #expect(await wait { !quit.helper.isRunning })
        #expect(!fm.fileExists(atPath: quit.ksMarker.path))
        #expect(quit.calls.contains("pfctl -X 42"))
    }

    @Test func killSwitchRefusesWhenPfWouldNotEvaluateItsAnchor() async throws {
        let s = try await start(core: liveCore, anchors: false)
        defer { s.cleanUp() }
        let flag = s.state.appendingPathComponent(KillSwitch.flag)
        try write("", to: KillSwitch.flag, in: s)
        #expect(await wait { !FileManager.default.fileExists(atPath: flag.path) }, "the helper takes the request back")
        let error = try String(contentsOf: s.root.appendingPathComponent(KillSwitch.errorFile), encoding: .utf8)
        #expect(error.contains("Apple's anchors"))
        #expect(!FileManager.default.fileExists(atPath: s.ksMarker.path))
        #expect(!s.calls.contains("pfctl -E"))
    }

    @Test func systemProxyFollowsThePortFileOnServicesWithADevice() async throws {
        let s = try await start(core: liveCore)
        defer { s.cleanUp() }
        let fm = FileManager.default
        try write("10808\n", to: SystemProxy.flag, in: s)
        #expect(await wait { s.calls.contains("networksetup -setsocksfirewallproxy USB 10/100 LAN 127.0.0.1 10808 off") })
        let set = s.calls.filter { $0.hasPrefix("networksetup -setwebproxy ") }
        #expect(set == ["networksetup -setwebproxy Wi-Fi 127.0.0.1 10808 off", "networksetup -setwebproxy USB 10/100 LAN 127.0.0.1 10808 off"])
        #expect(s.calls.contains("networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 10808 off"))

        try write("10901", to: SystemProxy.flag, in: s)
        #expect(await wait { s.calls.contains("networksetup -setwebproxy Wi-Fi 127.0.0.1 10901 off") })

        // Not a port: treated like no request.
        try write("80; reboot", to: SystemProxy.flag, in: s)
        #expect(await wait { s.calls.contains("networksetup -setwebproxystate Wi-Fi off") })
        #expect(!s.calls.contains { $0.contains("reboot") })

        try write("10808", to: SystemProxy.flag, in: s)
        #expect(await wait { s.calls.filter { $0 == "networksetup -setwebproxy Wi-Fi 127.0.0.1 10808 off" }.count == 2 })
        let before = s.calls.filter { $0.hasSuffix("proxystate Wi-Fi off") }.count
        try fm.removeItem(at: s.session)
        #expect(await wait { !s.helper.isRunning })
        #expect(s.calls.filter { $0.hasSuffix("proxystate Wi-Fi off") }.count == before + 3, "the session's end turns the proxies off")
    }

    @Test func refusesACoreThatChangedAfterItWasHashed() async throws {
        let s = try await start(core: liveCore, hash: String(repeating: "0", count: 64))
        defer { s.cleanUp() }
        #expect(await wait { !s.helper.isRunning })
        #expect(s.helper.terminationStatus == 1)
        #expect(!FileManager.default.fileExists(atPath: s.root.path))
    }

    @Test func stopsTheCoreWhenTheAppDies() async throws {
        let s = try await start(core: liveCore)
        defer { s.cleanUp() }
        FileManager.default.createFile(atPath: s.flag.path, contents: nil)
        #expect(await wait { s.childRunning })

        s.app.terminate()
        #expect(await wait { !s.helper.isRunning })
        #expect(!s.childRunning)
        #expect(!FileManager.default.fileExists(atPath: s.root.path))
    }

    @Test func aCoreThatDiesIsStartedAgainAndItsOutputIsKept() async throws {
        let s = try await start(core: "echo run >> \"$MARKER.count\"\necho 'Failed to start: app/proxyman/inbound: failed to start proxy > operation not permitted'\nexit 23")
        defer { s.cleanUp() }
        FileManager.default.createFile(atPath: s.flag.path, contents: nil)
        let count = URL(fileURLWithPath: s.marker.path + ".count")
        func runs() -> Int { ((try? String(contentsOf: count, encoding: .utf8)) ?? "").split(separator: "\n").count }

        #expect(await wait { runs() >= 1 })
        #expect(await wait { TunHelper.failureDetail(rootDirectory: s.root) == "operation not permitted" })
        #expect(await wait(6) { runs() >= 2 })
        #expect(runs() <= 3, "a failing core must not be restarted in a tight loop")
        #expect(s.helper.isRunning)
    }
}

@Suite(.tags(.integration), .enabled(if: TestSupport.coreAvailable))
struct TunIntegrationTests {
    func xrayTest(_ config: JSONValue) throws -> (status: Int32, output: String) {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try config.data().write(to: file)
        let p = Process()
        p.executableURL = TestSupport.xray
        p.arguments = ["run", "-test", "-c", file.path]
        p.environment = ["XRAY_LOCATION_ASSET": TestSupport.vendorCore.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    @Test func forwarderConfigPassesXrayTest() throws {
        let result = try xrayTest(ConfigBuilder.tunForwarder(interfaceName: "utun123", corePort: 10891))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("Configuration OK"))
    }

    @Test func coreConfigInTunModePassesXrayTest() throws {
        var options = RunOptions(
            inbound: InboundSettings(port: try PortUtil.freePort()),
            metricsPort: try PortUtil.freePort(),
            tun: TunLink(port: try PortUtil.freePort(), outboundInterface: "en0", resolvers: ["192.168.1.1", "fd00::1"])
        )
        options.dialer = DialerSettings(fragment: FragmentSettings())
        let named: JSONValue = ["protocol": "vless", "settings": ["vnext": [["address": "server.example.com", "port": 443, "users": [["id": "b831381d-6324-4d53-ad4f-8cda48b30811", "encryption": "none"]]]]],
                                "streamSettings": ["security": "tls"]]
        for outbound in [["protocol": "freedom"], named] as [JSONValue] {
            let result = try xrayTest(try ConfigBuilder.build(outbound: outbound, options: options, routing: .global))
            #expect(result.status == 0, Comment(rawValue: result.output))
        }
    }

    /// The forwarder hands every DNS query to `tun-in`, whichever resolver it was addressed to.
    /// Here one goes to an address nothing answers on (TEST-NET), the way a query to the
    /// router would: it must be answered all the same, by the core's resolver, which must ask
    /// through the server and not directly.
    @Test func everyLookupFromTheTunIsAnsweredThroughTheServer() async throws {
        let primary = try #require(NetworkInterfaces.primary(), "needs a network connection")
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["server", "core"] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true) }

        // The "server": a core that lets everything out and logs where each connection went.
        let serverOptions = RunOptions(inbound: InboundSettings(port: try PortUtil.freePort()), logConnections: true, metricsPort: try PortUtil.freePort())
        let server = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir.appendingPathComponent("server"))
        let serverLog = OSLockedBox<[String]>([])
        let serverLines = server.logs
        Task { for await line in serverLines { serverLog.mutate { $0.append(line) } } }
        try await server.start(config: try ConfigBuilder.build(outbound: ["protocol": "freedom"], options: serverOptions, routing: .global), readyPort: serverOptions.inbound.port)

        // This Mac's core in TUN mode, with that server as its proxy.
        let tunPort = try PortUtil.freePort()
        let options = RunOptions(
            inbound: InboundSettings(port: try PortUtil.freePort()), logConnections: true, metricsPort: try PortUtil.freePort(),
            tun: TunLink(port: tunPort, outboundInterface: primary)
        )
        let proxy: JSONValue = ["protocol": "socks", "settings": ["address": "127.0.0.1", "port": .number(Double(serverOptions.inbound.port))]]
        let core = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir.appendingPathComponent("core"))
        let coreLog = OSLockedBox<[String]>([])
        let coreLines = core.logs
        Task { for await line in coreLines { coreLog.mutate { $0.append(line) } } }
        try await core.start(config: try ConfigBuilder.build(outbound: proxy, options: options, routing: .global), readyPort: options.inbound.port)

        let answer = try await Task.detached { try SocksUDP.lookUp("example.com", resolver: [192, 0, 2, 53], socksPort: tunPort) }.value
        // Ordinary traffic from the TUN goes the same way.
        let web = await RealDelayTester.measureOne(port: tunPort, url: URL(string: "https://www.gstatic.com/generate_204")!, timeout: 15)
        try await Task.sleep(for: .milliseconds(500))
        await core.stop()
        await server.stop()

        #expect(answer.rcode == 0 && answer.answers > 0, "example.com through tun-in: \(answer)")
        #expect(coreLog.value.contains { $0.contains("192.0.2.53:53") && $0.contains("v2mac-dns-out") }, Comment(rawValue: coreLog.value.joined(separator: "\n")))
        #expect(!coreLog.value.contains { $0.contains("-> direct]") || $0.contains(">> direct]") }, "nothing may leave directly")
        // The core's resolver reached a DoH server only through the server.
        #expect(serverLog.value.contains { $0.contains("1.1.1.1:443") || $0.contains("8.8.8.8:443") }, Comment(rawValue: serverLog.value.joined(separator: "\n")))
        if case .ok = web {} else { Issue.record("request through tun-in failed: \(web)") }
        #expect(serverLog.value.contains { $0.contains("www.gstatic.com:443") })
    }

    /// The whole TUN path except the TUN itself: what the forwarder would send into `tun-in`
    /// comes out through an outbound bound to the real interface, and is counted.
    @Test func tunInboundCarriesTrafficThroughABoundOutbound() async throws {
        let primary = try #require(NetworkInterfaces.primary(), "needs a network connection")
        let tunPort = try PortUtil.freePort()
        let options = RunOptions(
            inbound: InboundSettings(port: try PortUtil.freePort()),
            metricsPort: try PortUtil.freePort(),
            tun: TunLink(port: tunPort, outboundInterface: primary)
        )
        let config = try ConfigBuilder.build(outbound: ["protocol": "freedom"], options: options, routing: .global)
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        try await runner.start(config: config, readyPort: options.inbound.port)

        let outcome = await RealDelayTester.measureOne(
            port: tunPort, url: URL(string: "https://www.gstatic.com/generate_204")!, timeout: 15
        )
        guard case .ok = outcome else {
            await runner.stop()
            Issue.record("request through tun-in failed: \(outcome)")
            return
        }
        let stats = try await StatsClient(port: options.metricsPort).snapshot()
        #expect(stats.downlink > 0)
        await runner.stop()
    }
}

/// A DNS query sent the way the TUN forwarder sends one: as a SOCKS5 UDP datagram into `tun-in`.
enum SocksUDP {
    struct Answer: CustomStringConvertible {
        var rcode: Int
        var answers: Int
        var description: String { "rcode \(rcode), \(answers) answers" }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func lookUp(_ name: String, resolver: [UInt8], socksPort: Int) throws -> Answer {
        let control = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(control) }
        try timeouts(control)
        var proxy = loopback(port: socksPort)
        guard withUnsafePointer(to: &proxy, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(control, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else {
            throw Failure(description: "connect to tun-in failed")
        }
        // No authentication, then UDP ASSOCIATE; the reply names the relay port.
        guard exchange(control, [5, 1, 0], expect: 2).starts(with: [5, 0]) else { throw Failure(description: "SOCKS greeting refused") }
        let reply = exchange(control, [5, 3, 0, 1, 0, 0, 0, 0, 0, 0], expect: 10)
        guard reply.count >= 10, reply[1] == 0 else { throw Failure(description: "UDP ASSOCIATE refused: \(reply)") }
        let relayPort = Int(reply[8]) << 8 | Int(reply[9])

        var query: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { query.append(UInt8(label.utf8.count)); query += Array(label.utf8) }
        query += [0, 0, 1, 0, 1]
        let datagram: [UInt8] = [0, 0, 0, 1] + resolver + [0, 53] + query

        let udp = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(udp) }
        try timeouts(udp)
        var relay = loopback(port: relayPort)
        let sent = datagram.withUnsafeBytes { bytes in
            withUnsafePointer(to: &relay) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(udp, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
        guard sent == datagram.count else { throw Failure(description: "send failed") }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = recv(udp, &buffer, buffer.count, 0)
        // 10 bytes of SOCKS header, then the DNS message.
        guard count > 22, buffer[10] == 0x12, buffer[11] == 0x34 else { throw Failure(description: "no DNS answer (\(count) bytes)") }
        return Answer(rcode: Int(buffer[13] & 0x0F), answers: Int(buffer[16]) << 8 | Int(buffer[17]))
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func timeouts(_ fd: Int32) throws {
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw Failure(description: "setsockopt failed")
        }
    }

    private static func exchange(_ fd: Int32, _ bytes: [UInt8], expect: Int) -> [UInt8] {
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Array(buffer.prefix(count)) : []
    }
}

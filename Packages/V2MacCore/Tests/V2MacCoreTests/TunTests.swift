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
        #expect(c["routing"]?["rules"]?[0]?["inboundTag"] == ["mixed-in", "tun-in"])

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
        #expect(c["routing"]?["rules"]?[0]?["port"]?.stringValue == "53")
        #expect(c["routing"]?["rules"]?[0]?["outboundTag"]?.stringValue == "direct")
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
    @Test func launchCommandQuotesEveryArgument() {
        let command = TunHelper.launchCommand(
            script: URL(fileURLWithPath: "/a b/helper.sh"), appPID: 42,
            stateDirectory: URL(fileURLWithPath: "/it's/run"), core: URL(fileURLWithPath: "/x/xray"),
            config: URL(fileURLWithPath: "/x/c.json"), rootDirectory: URL(fileURLWithPath: "/var/run/v2mac-tun-501")
        )
        #expect(command == #"/bin/sh '/a b/helper.sh' '42' '/it'\''s/run' '/x/xray' '/x/c.json' '/var/run/v2mac-tun-501' > /dev/null 2>&1 &"#)
    }

    @Test func appleScriptEscapesQuotesAndBackslashes() {
        let script = TunHelper.appleScript(command: #"echo "a\b""#, prompt: "Allow?")
        #expect(script == #"do shell script "echo \"a\\b\"" with prompt "Allow?" with administrator privileges"#)
    }

    @Test func rootDirectoryIsPerUser() {
        #expect(TunHelper.rootDirectory(uid: 501).path == "/var/run/v2mac-tun-501")
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

        func cleanUp() {
            if helper.isRunning { helper.terminate() }
            if app.isRunning { app.terminate() }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// `core` is the body of the stand-in core script; `$MARKER` names a file it may use.
    func start(core: String) throws -> Session {
        let fm = FileManager.default
        let dir = try TestSupport.makeTempDirectory()
        let state = dir.appendingPathComponent("state")
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let root = dir.appendingPathComponent("root")
        let marker = dir.appendingPathComponent("running")

        let script = dir.appendingPathComponent("helper.sh")
        try TunHelper.script.write(to: script, atomically: true, encoding: .utf8)
        let fake = dir.appendingPathComponent("fake-core")
        try "#!/bin/sh\nMARKER='\(marker.path)'\n\(core)\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let config = dir.appendingPathComponent("config.json")
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        fm.createFile(atPath: state.appendingPathComponent(TunHelper.sessionFlag).path, contents: nil)

        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["60"]
        try app.run()

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script.path, "\(app.processIdentifier)", state.path, fake.path, config.path, root.path]
        try helper.run()
        return Session(dir: dir, state: state, root: root, marker: marker, helper: helper, app: app)
    }

    let liveCore = "trap 'rm -f \"$MARKER\"; exit 0' TERM\ntouch \"$MARKER\"\nwhile :; do sleep 0.1; done"

    func wait(_ seconds: Double = 5, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func followsTheFlagAndEndsWithTheSession() async throws {
        let s = try start(core: liveCore)
        defer { s.cleanUp() }
        let fm = FileManager.default

        #expect(await wait { TunHelper.isAlive(rootDirectory: s.root) })
        #expect(fm.isExecutableFile(atPath: s.root.appendingPathComponent("xray").path))
        #expect(fm.fileExists(atPath: s.root.appendingPathComponent("config.json").path))
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

    @Test func stopsTheCoreWhenTheAppDies() async throws {
        let s = try start(core: liveCore)
        defer { s.cleanUp() }
        FileManager.default.createFile(atPath: s.flag.path, contents: nil)
        #expect(await wait { s.childRunning })

        s.app.terminate()
        #expect(await wait { !s.helper.isRunning })
        #expect(!s.childRunning)
        #expect(!FileManager.default.fileExists(atPath: s.root.path))
    }

    @Test func aCoreThatDiesIsStartedAgainAndItsOutputIsKept() async throws {
        let s = try start(core: "echo run >> \"$MARKER.count\"\necho 'Failed to start: app/proxyman/inbound: failed to start proxy > operation not permitted'\nexit 23")
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
        let options = RunOptions(
            inbound: InboundSettings(port: try PortUtil.freePort()),
            metricsPort: try PortUtil.freePort(),
            tun: TunLink(port: try PortUtil.freePort(), outboundInterface: "en0")
        )
        let result = try xrayTest(try ConfigBuilder.build(outbound: ["protocol": "freedom"], options: options, routing: .global))
        #expect(result.status == 0, Comment(rawValue: result.output))
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

import Foundation
import SwiftData
import Testing
import V2MacCore

/// No app host, administrator prompt or real TUN. Every core gets its own temporary directory.
@Suite(.serialized) @MainActor
struct ConnectionAutomationTests {
    private static var vendor: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/core")
    }

    private func wait(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func server(_ config: JSONValue = ["protocol": "freedom"], index: Int = 0, kind: ProfileKind = .outbound) throws -> ActiveServer {
        let parsed = ParsedProfile(name: "Demo \(index)", kind: kind, protocolName: "freedom",
                                   address: "example.com", port: 443, transport: "raw", security: "none", config: config)
        return try #require(ActiveServer(Profile(parsed: parsed, sortIndex: index, group: nil)))
    }

    private func withController(
        policy: TunFailurePolicy = .continueProxy, auto: Bool = false, tunEnabled: Bool = false, killSwitch: Bool = false, delayLimit: Int? = nil,
        authorize: @escaping @MainActor (String) async -> TunController.LaunchResult = { _ in .cancelled },
        helperIsAlive: @escaping @MainActor (URL) -> Bool = { _ in false },
        interfaceExists: @escaping @MainActor (String) -> Bool = { _ in false },
        body: (ConnectionController, URL) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let keys = ["autoSelectServer", "tunFailurePolicy", "tunEnabled", "checkExit", "proxyPort", "wasRunning", "activeProfileID",
                    "latencyURL", "latencyTimeout", "routingMode", "killSwitch", "switchOnDelay", "switchDelayMs"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        }
        Prefs.registerDefaults()
        defaults.set(auto, forKey: "autoSelectServer")
        defaults.set(policy.rawValue, forKey: "tunFailurePolicy")
        defaults.set(tunEnabled, forKey: "tunEnabled")
        defaults.set(killSwitch, forKey: "killSwitch")
        defaults.set(delayLimit != nil, forKey: "switchOnDelay")
        defaults.set(delayLimit ?? 1000, forKey: "switchDelayMs")
        defaults.set(false, forKey: "checkExit")
        defaults.set("http://example.com/probe", forKey: "latencyURL")
        defaults.set(0.5, forKey: "latencyTimeout")
        Prefs.routingMode = .global
        Prefs.port = try PortUtil.freePort()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-state-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = LogStore()
        let tun = TunController(logs: logs, stateDirectory: directory.appendingPathComponent("tun"),
                                rootDirectory: directory.appendingPathComponent("helper"),
                                primaryInterface: { _ in "en0" }, authorize: authorize,
                                helperIsAlive: helperIsAlive, interfaceExists: interfaceExists,
                                core: { Self.vendor.appendingPathComponent("xray") })
        let controller = ConnectionController(logs: logs, executable: { Self.vendor.appendingPathComponent("xray") },
                                              assetDirectory: Self.vendor, runDirectory: directory.appendingPathComponent("run"),
                                              tun: tun, monitorsLifecycle: false, healthInterval: .milliseconds(200))
        do { try await body(controller, directory) }
        catch { await controller.shutdown(); throw error }
        await controller.shutdown()
    }

    @Test func automaticSelectionIsOffByDefault() {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "autoSelectServer")
        defaults.removeObject(forKey: "autoSelectServer")
        defer { if let old { defaults.set(old, forKey: "autoSelectServer") } }
        Prefs.registerDefaults()
        #expect(!Prefs.autoSelectServer)
    }

    @Test(arguments: [false, true])
    func launchPreservesTunChoiceSelectedServerAndReconnectState(tunEnabled: Bool) async throws {
        try await withController(tunEnabled: tunEnabled) { controller, directory in
            let selected = try server()
            controller.setActive(selected)
            Prefs.wasRunning = true

            Prefs.registerDefaults()

            #expect(Prefs.tunEnabled == tunEnabled)
            #expect(Prefs.activeProfileID == selected.id)
            #expect(Prefs.wasRunning)
            let restoredTun = TunController(logs: LogStore(), stateDirectory: directory.appendingPathComponent("restored"),
                                            rootDirectory: directory.appendingPathComponent("restored-helper"),
                                            authorize: { _ in Issue.record("Restoring a setting must not authorize TUN"); return .cancelled })
            #expect(restoredTun.isEnabled == tunEnabled)
            #expect(restoredTun.state == .off)
        }
    }

    @Test func cancelledAuthorizationStopsTheProxyUnderStrictPolicy() async throws {
        try await withController(policy: .stopProxy, tunEnabled: true) { controller, directory in
            controller.setActive(try server())
            controller.connectActive()
            #expect(await wait { if case .failed = controller.phase { true } else { false } })
            #expect(!controller.isRunning)
            #expect(controller.tun.isEnabled)
            #expect(controller.tun.failureMessage?.contains("cancelled") == true)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("run/xray.pid").path))
            #expect(!Prefs.wasRunning)
        }
    }

    @Test func killSwitchThatCannotGoUpKeepsTheConnectionDown() async throws {
        try await withController(killSwitch: true) { controller, directory in
            controller.setActive(try server())
            controller.connectActive()
            #expect(await wait { if case .failed = controller.phase { true } else { false } })
            #expect(controller.localError?.contains("kill switch") == true)
            #expect(controller.killSwitch.state == .failed("Administrator access was cancelled."))
            #expect(!controller.isRunning)
            #expect(!Prefs.wasRunning)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("tun/\(KillSwitch.flag)").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("run/xray.pid").path))
        }
    }

    @Test func cancelledAuthorizationCanExplicitlyKeepOnlyTheLocalProxy() async throws {
        try await withController(tunEnabled: true) { controller, _ in
            controller.setActive(try server())
            controller.connectActive()
            #expect(await wait { controller.isRunning })
            #expect(!controller.tun.isOn)
            #expect(controller.connectedTitle == "Local proxy connected")
            #expect(controller.tun.failureMessage != nil)
            #expect(controller.tun.statusNote == "System tunnel unavailable")
        }
    }

    @Test func disconnectDuringAuthorizationCannotConnectLater() async throws {
        try await withController(tunEnabled: true, authorize: { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return .cancelled
        }) { controller, directory in
            controller.setActive(try server())
            controller.connectActive()
            #expect(await wait { controller.tun.state == .authorizing })
            controller.disconnect()
            try await Task.sleep(for: .milliseconds(600))
            #expect(!controller.isRunning)
            #expect(controller.phase == .off)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("run/xray.pid").path))
        }
    }

    @Test func disabledAutomationNeverTestsOtherServers() async throws {
        try await withController { controller, _ in
            var queried = false
            controller.automaticCandidates = { _ in queried = true; return [] }
            controller.setActive(try server())
            controller.connectActive()
            #expect(await wait { controller.isRunning })
            #expect(!queried)
        }
    }

    @Test func disconnectDuringAutomaticTestingCannotApplyLateResults() async throws {
        try await withController(auto: true) { controller, _ in
            let unreachable = try server(["protocol": "blackhole"])
            controller.setActive(unreachable)
            controller.automaticCandidates = { _ in [unreachable] }
            controller.connectActive()
            #expect(await wait { controller.isSelectingAutomatically })
            controller.disconnect()
            try await Task.sleep(for: .milliseconds(500))
            #expect(!controller.isRunning)
            #expect(!controller.isSelectingAutomatically)
            #expect(controller.activeServer?.id == unreachable.id)
        }
    }

    private func outbound(to port: Int) -> JSONValue {
        ["protocol": "freedom", "settings": ["redirect": .string("127.0.0.1:\(port)")]]
    }

    @Test func initialSelectionChoosesFastestRealResponseThenFallbackUsesGroupOrder() async throws {
        let fastResponse = ResponseSwitch()
        let fast = try await TestHTTPServer.start { _ in fastResponse.get() }
        let slow = try await TestHTTPServer.start { _ in .init(status: 204, responseDelay: 0.25) }
        let next = try await TestHTTPServer.start { _ in .init(status: 204, responseDelay: 0.1) }
        defer { fast.stop(); slow.stop(); next.stop() }
        try await withController(auto: true) { controller, _ in
            let orderedFirst = try server(outbound(to: slow.port), index: 0)
            let fastest = try server(outbound(to: fast.port), index: 1)
            let orderedLast = try server(outbound(to: next.port), index: 2)
            controller.automaticCandidates = { _ in [orderedFirst, fastest, orderedLast] }
            controller.setActive(orderedFirst)
            controller.connectActive()
            #expect(await wait { controller.isRunning && controller.activeServer?.id == fastest.id })
            // A manual pick clears the initial switch cooldown, and remains pinned until failure.
            controller.activate(fastest)
            #expect(await wait { controller.phase == .connected })
            fastResponse.fail()
            #expect(await wait { controller.isRunning && controller.activeServer?.id == orderedFirst.id })
        }
    }

    @Test func aServerThatStaysSlowIsLeftForAFasterOneWhenThatConditionIsOn() async throws {
        let slowHTTP = try await TestHTTPServer.start { _ in .init(status: 204, responseDelay: 0.3) }
        let fastHTTP = try await TestHTTPServer.start { _ in .init(status: 204) }
        defer { slowHTTP.stop(); fastHTTP.stop() }
        try await withController(auto: true, delayLimit: 150) { controller, _ in
            let slow = try server(outbound(to: slowHTTP.port), index: 0)
            let fast = try server(outbound(to: fastHTTP.port), index: 1)
            controller.automaticCandidates = { _ in [slow, fast] }
            // Picked by hand: the condition still applies.
            controller.activate(slow)
            #expect(await wait { controller.isRunning })
            #expect(await wait { controller.isRunning && controller.activeServer?.id == fast.id })
        }
    }

    @Test func manualChoiceIsNotReplacedByAFasterWorkingPeer() async throws {
        let http = try await TestHTTPServer.start { _ in .init(status: 204) }
        defer { http.stop() }
        try await withController(auto: true) { controller, _ in
            let manual = try server(outbound(to: http.port))
            var testedPeers = false
            controller.automaticCandidates = { _ in testedPeers = true; return [] }
            controller.activate(manual)
            #expect(await wait { controller.isRunning })
            try await Task.sleep(for: .milliseconds(700))
            #expect(controller.activeServer?.id == manual.id)
            #expect(!testedPeers)
        }
    }

    @Test func losingTheTunHelperStopsARunningProxyUnderStrictPolicy() async throws {
        var alive = true
        var exists = true
        try await withController(policy: .stopProxy, tunEnabled: true, authorize: { _ in .started },
                                 helperIsAlive: { _ in alive }, interfaceExists: { _ in exists }) { controller, _ in
            controller.setActive(try server())
            controller.connectActive()
            #expect(await wait { controller.isRunning && controller.tun.isOn })
            alive = false
            exists = false
            #expect(await wait { !controller.isRunning && controller.localError != nil })
            #expect(controller.tun.failureMessage?.contains("helper stopped") == true)
            #expect(!Prefs.wasRunning)
        }
    }

    @Test func disablingAutomaticSelectionDuringATestConnectsTheChosenServerNormally() async throws {
        try await withController(auto: true) { controller, _ in
            let chosen = try server(["protocol": "blackhole"])
            controller.setActive(chosen)
            controller.automaticCandidates = { _ in [chosen] }
            controller.connectActive()
            #expect(await wait { controller.isSelectingAutomatically })
            UserDefaults.standard.set(false, forKey: "autoSelectServer")
            controller.autoSelectionChanged()
            #expect(await wait { controller.isRunning })
            #expect(controller.activeServer?.id == chosen.id)
            #expect(!controller.isSelectingAutomatically)
        }
    }

    @Test func directRoutingDoesNotSelectAProxyAutomatically() async throws {
        try await withController(auto: true) { controller, _ in
            controller.setRoutingMode(.direct)
            var queried = false
            controller.automaticCandidates = { _ in queried = true; return [] }
            controller.setActive(try server())
            controller.connectActive()
            #expect(await wait { controller.isRunning })
            #expect(!queried)
        }
    }

    @Test(arguments: [RoutingMode.global, .bypassRegions, .direct], [ProfileKind.outbound, .custom])
    func connectionMonitorKeepsTheRunningRoutingMode(mode: RoutingMode, kind: ProfileKind) async throws {
        try await withController { controller, _ in
            controller.setRoutingMode(mode)
            let config: JSONValue = kind == .custom ? ["outbounds": [["protocol": "freedom"]]] : ["protocol": "freedom"]
            controller.setActive(try server(config, kind: kind))
            controller.connectActive()
            #expect(await wait { controller.isRunning })
            #expect(controller.watcher.routingMode == mode)
            #expect(controller.watcher.hasConfigFallback == (kind == .custom))
            controller.watcher.watch()
            defer { controller.watcher.unwatch() }
            controller.watcher.record(try #require(SeenConnection(line: "x from 127.0.0.1:50000 accepted tcp:example.com:443 [tun-in -> proxy]")))
            #expect(await wait { !controller.watcher.connections.isEmpty })
            #expect(controller.watcher.connections.first?.routingMode == mode)
        }
    }

    @Test func unavailableGroupDoesNotConnectAnUntestedServer() async throws {
        try await withController(auto: true) { controller, _ in
            let unavailable = try server(["protocol": "blackhole"])
            controller.setActive(unavailable)
            controller.automaticCandidates = { _ in [unavailable] }
            controller.connectActive()
            #expect(await wait { controller.localError?.contains("No working server") == true })
            #expect(!controller.isRunning)
            #expect(controller.healthFailed)
        }
    }

    @Test func noFallbackKeepsTheProxyControllableAndRecoversItsHealthStatus() async throws {
        let response = ResponseSwitch()
        let http = try await TestHTTPServer.start { _ in response.get() }
        defer { http.stop() }
        try await withController(auto: true) { controller, _ in
            let chosen = try server(outbound(to: http.port))
            controller.automaticCandidates = { _ in [chosen] }
            controller.activate(chosen)
            #expect(await wait { controller.isRunning })
            response.fail()
            #expect(await wait { controller.healthFailed && !controller.isSelectingAutomatically })
            #expect(controller.phase == .connected)
            response.recover()
            #expect(await wait { !controller.healthFailed && controller.phase == .connected })
            controller.disconnect()
            #expect(await wait { controller.phase == .off })
        }
    }

    @Test func removingACandidateWhileItIsTestedCannotActivateIt() async throws {
        let http = try await TestHTTPServer.start { _ in .init(status: 204, responseDelay: 0.2) }
        defer { http.stop() }
        try await withController(auto: true) { controller, _ in
            let chosen = try server(outbound(to: http.port))
            var queries = 0
            controller.automaticCandidates = { _ in
                queries += 1
                return queries == 1 ? [chosen] : []
            }
            controller.setActive(chosen)
            controller.connectActive()
            #expect(await wait { controller.localError?.contains("No working server") == true })
            #expect(!controller.isRunning)
        }
    }
}

private final class ResponseSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var response = TestHTTPServer.Response(status: 204)
    func get() -> TestHTTPServer.Response { lock.withLock { response } }
    func fail() { lock.withLock { response.withholdResponse = true } }
    func recover() { lock.withLock { response.withholdResponse = false } }
}

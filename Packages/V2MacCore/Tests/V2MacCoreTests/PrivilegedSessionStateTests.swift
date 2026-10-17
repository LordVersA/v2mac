import Foundation
import Testing
@testable import V2MacCore

@Suite struct PrivilegedSessionStateTests {
    @Test func acceptsOnlyBoundedSessionPortsAndUtunNames() throws {
        try PrivilegedSessionState.validate(port: 10890, interfaceName: "utun100")
        try PrivilegedSessionState.validate(port: 65535, interfaceName: "utun65535")
        for port in [-1, 0, 80, 65536, Int.max] {
            #expect(throws: (any Error).self) { try PrivilegedSessionState.validate(port: port, interfaceName: "utun100") }
        }
        for name in ["", "en0", "utun0", "utun", "utun65536", "utun-100", "utun１００", "utun100; touch /tmp/unwanted", "utun100\n"] {
            #expect(throws: (any Error).self) { try PrivilegedSessionState.validate(port: 10890, interfaceName: name) }
        }
    }

    @Test func rejectsNonAddressFirewallInputAndOversizedMessages() throws {
        let valid = PrivilegedSessionState(tunEnabled: true, proxyPort: 10808, killSwitchEnabled: true,
                                          allowedAddresses: ["1.1.1.1", "2001:db8::1"])
        #expect(try PrivilegedSessionState.decode(JSONEncoder().encode(valid)) == valid)
        for address in ["example.com", "0.0.0.0/0", "1.1.1.1\npass all", "::1%en0", "$(id)"] {
            var invalid = valid
            invalid.allowedAddresses = [address]
            #expect(throws: (any Error).self) { try invalid.validate() }
        }
        var invalid = valid
        invalid.proxyPort = 0
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = valid
        invalid.allowedAddresses = Array(repeating: "1.1.1.1", count: 4097)
        #expect(throws: (any Error).self) { try invalid.validate() }
        #expect(throws: (any Error).self) { try PrivilegedSessionState.decode(Data(repeating: 0, count: 256 * 1024 + 1)) }
        #expect(throws: (any Error).self) { try PrivilegedSessionState.decode(Data("{}".utf8)) }
    }

    @Test func writesValidatedRequestsAndClearsAllPrivilegesOnStop() throws {
        let directory = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let running = PrivilegedSessionState(tunEnabled: true, proxyPort: 10818, killSwitchEnabled: true,
                                            allowedAddresses: ["192.0.2.1", "2001:db8::1"])
        try running.write(to: directory)
        #expect(try String(contentsOf: directory.appendingPathComponent(SystemProxy.flag), encoding: .utf8) == "10818\n")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(TunHelper.onFlag).path))
        let stopped = PrivilegedSessionState(tunEnabled: false, proxyPort: nil, killSwitchEnabled: false, allowedAddresses: [])
        try stopped.write(to: directory)
        #expect(try String(contentsOf: directory.appendingPathComponent(KillSwitch.allowFile), encoding: .utf8) == "\n")
        for flag in [TunHelper.onFlag, SystemProxy.flag, KillSwitch.flag] {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(flag).path))
        }
    }

}

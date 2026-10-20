import Foundation
import Testing
@testable import V2MacCore

@Suite struct KillSwitchTests {
    @Test func rulesAreValidPf() throws {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        check.arguments = ["-n", "-f", "-"]
        let input = Pipe()
        let output = Pipe()
        check.standardInput = input
        check.standardError = output
        check.standardOutput = output
        try check.run()
        // The helper writes the rules with a final newline, which pf needs.
        input.fileHandleForWriting.write(Data((KillSwitch.rules(tunInterface: "utun123") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check.waitUntilExit()
        #expect(check.terminationStatus == 0, "\(text)")
    }

    /// The helper checks the allow list on every turn of its loop: an unchanged list starts no process.
    @Test func allowListIsReloadedOnlyWhenItChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["cksum", "pfctl", "grep"] {
            let stub = bin.appendingPathComponent(tool)
            let real = tool == "pfctl" ? "true" : "/usr/bin/\(tool) \"$@\""
            try "#!/bin/sh\necho \(tool) >> \"\(dir.path)/calls\"\nexec \(real)\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        let script = """
        PATH="\(bin.path):/usr/bin:/bin"; STATE_DIR="\(dir.path)"; ROOT_DIR="\(dir.path)"; KS_ANCHOR=a; KS_MARKER="\(dir.path)/none"
        \(TunHelper.killSwitchFunctions)
        echo 1.2.3.4 > "$STATE_DIR/killswitch.allow"
        ks_allow; ks_allow; ks_allow
        echo 5.6.7.8 >> "$STATE_DIR/killswitch.allow"
        ks_allow; ks_allow
        """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        try shell.run()
        shell.waitUntilExit()
        let calls = try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        #expect(calls.filter { $0 == "pfctl" }.count == 2)
        #expect(!calls.contains("cksum"))
        #expect(try String(contentsOf: dir.appendingPathComponent("allow"), encoding: .utf8) == "1.2.3.4\n5.6.7.8\n")
    }

    @Test func rulesEndWithTheBlockAndPassOnlyWhatTheyShould() {
        let lines = KillSwitch.rules(tunInterface: "utun123").split(separator: "\n")
        #expect(lines.last == "block return out quick all")
        #expect(lines.contains("pass out quick on utun123 all flags any no state"))
        #expect(lines.filter { $0.hasPrefix("pass") }.allSatisfy { $0.hasSuffix("no state") })
    }

    @Test func hostsOfAnOutboundAndOfAFullConfig() {
        let outbound: JSONValue = ["protocol": "vless", "settings": ["vnext": [["address": "a.example.com", "port": 443]]]]
        #expect(KillSwitch.hosts(in: outbound, kind: .outbound) == ["a.example.com"])
        let custom: JSONValue = ["outbounds": [
            ["protocol": "trojan", "settings": ["servers": [["address": "203.0.113.7", "port": 443]]]],
            ["protocol": "wireguard", "settings": ["peers": [["endpoint": "[2001:db8::1]:51820"], ["endpoint": "wg.example.com:51820"]]]],
            ["protocol": "socks", "settings": ["servers": [["address": "127.0.0.1", "port": 9050]]]],
            ["protocol": "freedom"],
        ]]
        #expect(KillSwitch.hosts(in: custom, kind: .custom) == ["2001:db8::1", "203.0.113.7", "wg.example.com"])
    }

    @Test func addressesKeepLiteralsAndResolveNames() async {
        let found = await KillSwitch.addresses(of: ["203.0.113.7", "2001:db8::1", "localhost"])
        #expect(found.contains("203.0.113.7"))
        #expect(found.contains("2001:db8::1"))
        #expect(found.contains("127.0.0.1"))
        #expect(found.allSatisfy { !$0.contains("%") })
    }
}

@Suite struct SystemProxyTests {
    @Test func stateOfTheSettings() {
        #expect(SystemProxy.state(of: [:], port: 10808) == .none)
        #expect(SystemProxy.state(of: ["HTTPEnable": 0, "SOCKSEnable": 0], port: 10808) == .none)
        let ours: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 10808,
                                   "SOCKSEnable": 1, "SOCKSProxy": "localhost", "SOCKSPort": 10808]
        #expect(SystemProxy.state(of: ours, port: 10808) == .ours)
        #expect(SystemProxy.state(of: ours, port: 10809) == .other)
        var mixed = ours
        mixed["HTTPSEnable"] = 1
        mixed["HTTPSProxy"] = "10.0.0.2"
        mixed["HTTPSPort"] = 3128
        #expect(SystemProxy.state(of: mixed, port: 10808) == .other)
        #expect(SystemProxy.state(of: ["ProxyAutoConfigEnable": 1], port: 10808) == .other)
    }
}

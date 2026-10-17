import Foundation
import Security
import Testing

@Suite struct PeerCodeSigningTests {
    @Test func productionRuleUsesValidSecurityFrameworkSyntax() throws {
        let base = try PeerCodeSigning.requirement(identifier: PrivilegedHelperIdentity.appIdentifier, team: "TESTTEAM12")
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString((base + PeerCodeSigning.releaseRestriction) as CFString, [], &requirement)
        #expect(status == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test func productionRuleRejectsDebuggableCodeAndAllowsFalseOrAbsentEntitlements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-signature-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var requirement: SecRequirement?
        let expression = String(PeerCodeSigning.releaseRestriction.dropFirst(" and ".count))
        #expect(SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess)
        let parsed = try #require(requirement)
        for (index, debugging) in ([nil, false, true] as [Bool?]).enumerated() {
            let binary = directory.appendingPathComponent("fixture-\(index)")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
            let entitlements = directory.appendingPathComponent("entitlements.plist")
            let values: [String: Bool] = debugging.map { ["com.apple.security.get-task-allow": $0] } ?? [:]
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: entitlements)
            let signer = Process()
            signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signer.arguments = ["--force", "--sign", "-", "--entitlements", entitlements.path, binary.path]
            signer.standardOutput = FileHandle.nullDevice
            signer.standardError = FileHandle.nullDevice
            try signer.run()
            signer.waitUntilExit()
            try #require(signer.terminationStatus == 0)
            var code: SecStaticCode?
            #expect(SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess)
            let checked = try #require(code)
            let status = SecStaticCodeCheckValidity(checked, [], parsed)
            #expect((status == errSecSuccess) == (debugging != true))
        }
    }

    @Test func peerRequirementsPinBothPublisherAndExecutableIdentity() throws {
        let app = try PeerCodeSigning.requirement(identifier: PrivilegedHelperIdentity.appIdentifier, team: "TESTTEAM12")
        let helper = try PeerCodeSigning.requirement(identifier: PrivilegedHelperIdentity.serviceName, team: "TESTTEAM12")
        #expect(app.contains("anchor apple generic"))
        #expect(app.contains("certificate leaf[subject.OU] = \"TESTTEAM12\""))
        #expect(app != helper)
        #expect(helper.contains("identifier \"\(PrivilegedHelperIdentity.serviceName)\""))
    }

    @Test func requirementInputsCannotInjectAWeakerSigningRule() throws {
        for team in ["", "team", "TEAM\" or always", "TEAM\n"] {
            #expect(throws: (any Error).self) { try PeerCodeSigning.requirement(identifier: PrivilegedHelperIdentity.appIdentifier, team: team) }
        }
        #expect(throws: (any Error).self) { try PeerCodeSigning.requirement(identifier: "app\" or always", team: "TESTTEAM12") }
    }

    @Test func unrelatedSignedExecutablesCannotBecomeTheRootForwarder() {
        #expect(throws: (any Error).self) {
            try PeerCodeSigning.validate(URL(fileURLWithPath: "/bin/sh"), identifier: PrivilegedHelperIdentity.appIdentifier + ".xray", team: "TESTTEAM12")
        }
    }
}

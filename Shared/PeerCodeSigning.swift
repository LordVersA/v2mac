import Foundation
import Security

/// Requirements are enforced by XPC on every message, without a PID-based identity check.
enum PeerCodeSigning {
    static let releaseRestriction = " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              (try? requirement(identifier: PrivilegedHelperIdentity.serviceName, team: team)) != nil else { return nil }
        return team
    }

    static func requirement(identifier: String, team: String) throws -> String {
        guard !team.isEmpty, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              !identifier.isEmpty, identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 46 || $0 == 45 }) else { throw CocoaError(.coderInvalidValue) }
        var requirement = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        #if !DEBUG
        requirement += releaseRestriction
        #endif
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
            throw CocoaError(.coderInvalidValue)
        }
        return requirement
    }

    static func validate(_ file: URL, identifier: String, team: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = try self.requirement(identifier: identifier, team: team)
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { throw CocoaError(.executableNotLoadable) }
    }
}

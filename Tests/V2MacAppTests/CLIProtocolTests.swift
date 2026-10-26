import Foundation
import Testing

@Suite struct CLIProtocolTests {
    @Test func responseEnvelopeKeepsV1Fields() throws {
        let response = CLIWireResponse(ok: false, command: "rules apply", revision: "abc", data: nil,
                                       warnings: ["skipped"], error: .init(id: "conflict", message: "stale", exitCode: EX_TEMPFAIL), appHash: "def")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(object["apiVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == false)
        #expect(object["command"] as? String == "rules apply")
        #expect(object["revision"] as? String == "abc")
        #expect(object["warnings"] != nil)
        #expect(object["error"] != nil)
    }

    @Test func developmentEndpointCannotReachProduction() {
        #if DEBUG
        #expect(V2MacCLIIdentity.endpointName.contains("dev"))
        #expect(V2MacCLIIdentity.dataFolder == "v2mac-dev")
        #else
        #expect(!V2MacCLIIdentity.endpointName.contains("dev"))
        #expect(V2MacCLIIdentity.dataFolder == "v2mac")
        #endif
    }
}

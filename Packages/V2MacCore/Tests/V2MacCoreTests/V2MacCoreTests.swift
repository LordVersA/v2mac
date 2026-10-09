import Testing
@testable import V2MacCore

@Test func versionIsSet() {
    #expect(!V2MacCore.version.isEmpty)
}

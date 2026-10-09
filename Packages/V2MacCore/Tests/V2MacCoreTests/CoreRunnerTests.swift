import Foundation
import Testing
@testable import V2MacCore

@Suite struct PortUtilTests {
    @Test func freePortIsFree() throws {
        let port = try PortUtil.freePort()
        #expect(PortUtil.isFree(port: port))
    }

    @Test func heldPortIsBusy() throws {
        let holder = try TestSupport.PortHolder()
        defer { holder.release() }
        #expect(!PortUtil.isFree(port: holder.port))
        #expect(PortUtil.canConnect(port: holder.port))
    }

    @Test func invalidPortIsNotFree() {
        #expect(!PortUtil.isFree(port: 0))
        #expect(!PortUtil.isFree(port: 70000))
    }
}

@Suite struct CoreOutputParserTests {
    @Test func readinessLine() {
        #expect(CoreOutputParser.indicatesReady("2026/10/09 [Warning] core: Xray 26.9.30 started"))
        #expect(!CoreOutputParser.indicatesReady("[Warning] core: Xray 26.9.30 starting"))
    }

    @Test func takesLastSegmentOfFailureChain() {
        let line = #"Failed to start: main: failed to load config > infra/conf: "allowInsecure" has been removed"#
        #expect(CoreOutputParser.failureDetail(from: ["noise", line]) == #"infra/conf: "allowInsecure" has been removed"#)
    }

    @Test func fallsBackToLastLine() {
        #expect(CoreOutputParser.failureDetail(from: ["a", "b", ""]) == "b")
    }

    @Test func detectsBusyPort() {
        #expect(CoreOutputParser.indicatesPortBusy(["listen tcp 127.0.0.1:1: bind: address already in use"]))
    }
}

@Suite struct CoreRunnerFailureTests {
    @Test func missingCoreFails() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CoreRunner(
            executable: dir.appendingPathComponent("nope"),
            assetDirectory: dir,
            runDirectory: dir.appendingPathComponent("run")
        )
        await #expect(throws: CoreError.self) {
            try await runner.start(config: [:], readyPort: 1)
        }
        guard case .failed = await runner.state else {
            Issue.record("expected failed state")
            return
        }
        await runner.stop()
        #expect(await runner.state == .stopped)
    }

    @Test(.tags(.integration), .enabled(if: TestSupport.coreAvailable))
    func busyPortIsReportedBeforeLaunch() async throws {
        let holder = try TestSupport.PortHolder()
        defer { holder.release() }
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CoreRunner(executable: TestSupport.xray, assetDirectory: TestSupport.vendorCore, runDirectory: dir)
        await #expect(throws: CoreError.portInUse(holder.port)) {
            try await runner.start(config: [:], readyPort: holder.port)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
    }
}

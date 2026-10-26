import AppKit
import ArgumentParser
import CryptoKit
import Foundation

@main
struct V2MacCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "v2mac",
        abstract: "Control V2Mac and manage routing rules.",
        discussion: "Rule writes require --revision. Use --json for the stable v1 response envelope."
    )

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments")
    var arguments: [String] = []

    mutating func run() throws {
        guard !arguments.isEmpty else { throw CleanExit.helpRequest(self) }
        if arguments == ["--help"] || arguments == ["-h"] {
            print(Self.help)
            return
        }
        let json = arguments.contains("--json")
        do {
            let response = try send(arguments: arguments)
            let decoded = try JSONDecoder().decode(CLIWireResponse.self, from: Data(response.utf8))
            if json {
                print(response)
            } else {
                if let error = decoded.error {
                    FileHandle.standardError.write(Data((error.message + "\n").utf8))
                    Foundation.exit(error.exitCode)
                }
                if let data = decoded.data { print(data) }
                decoded.warnings.forEach { FileHandle.standardError.write(Data(("warning: \($0)\n").utf8)) }
                if let revision = decoded.revision { FileHandle.standardError.write(Data(("revision: \(revision)\n").utf8)) }
            }
            if let error = decoded.error { Foundation.exit(error.exitCode) }
        } catch let error as CLIClientError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            Foundation.exit(error.code)
        }
    }

    private static let help = """
    OVERVIEW: Control V2Mac and manage routing rules.

    USAGE: v2mac <command> [options]

    COMMANDS:
      version  status  connect  disconnect
      rules list|show|create|update|delete|enable|disable|move
      rules items add|remove
      rules targets list
      rules test|validate|export|apply|import
      rules tidy list|apply
      rules templates list|create
      rules profiles list|create|rename|delete|switch
      rules built-ins show|set

    Every write requires --revision. All mutations accept --dry-run. Use --json for the v1 envelope.
    """

    private func send(arguments: [String]) throws -> String {
        let command = arguments.first ?? ""
        var endpoint = try loadEndpoint()
        if endpoint == nil, command != "status", command != "version" {
            try launchApp()
            let limit = Date().addingTimeInterval(10)
            while endpoint == nil, Date() < limit {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                endpoint = try loadEndpoint()
            }
        }
        guard let endpoint else {
            let app = containingApp()
            let local = CLIWireResponse(ok: command == "version" || command == "status", command: command,
                                        data: command == "version" ? (Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") : "not running",
                                        error: nil, appHash: (try? hash(app.appendingPathComponent("Contents/MacOS/" + app.deletingPathExtension().lastPathComponent))) ?? "")
            return String(decoding: try JSONEncoder().encode(local), as: UTF8.self)
        }
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: V2MacCLIProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let input = arguments.contains("-") ? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) : nil
        let request = CLIWireRequest(arguments: arguments, stdin: input, clientHash: try hash(Bundle.main.executableURL!))
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let result = LockedBox<String>()
        let failure = LockedBox<Error>()
        let semaphore = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in failure.set(error); semaphore.signal() } as! V2MacCLIProtocol
        proxy.request(payload) { value in result.set(value); semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 12) == .success, let result = result.get() else {
            throw CLIClientError(failure.get()?.localizedDescription ?? "V2Mac did not respond.", EX_UNAVAILABLE)
        }
        let response = try JSONDecoder().decode(CLIWireResponse.self, from: Data(result.utf8))
        let app = containingApp()
        guard response.appHash == (try? hash(app.appendingPathComponent("Contents/MacOS/" + app.deletingPathExtension().lastPathComponent))) else {
            throw CLIClientError("The endpoint is not the V2Mac build containing this tool.", EX_NOPERM)
        }
        return result
    }

    private func loadEndpoint() throws -> NSXPCListenerEndpoint? {
        guard let data = try? Data(contentsOf: V2MacCLIIdentity.endpointURL) else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: NSXPCListenerEndpoint.self, from: data)
    }

    private func launchApp() throws {
        let app = containingApp()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--cli-background"]
        let semaphore = DispatchSemaphore(value: 0)
        let launchError = LockedBox<Error>()
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in if let error { launchError.set(error) }; semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 5)
        if let launchError = launchError.get() { throw launchError }
    }

    private func containingApp() -> URL {
        Bundle.main.executableURL!.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

private struct CLIClientError: Error {
    var message: String
    var code: Int32
    init(_ message: String, _ code: Int32) { self.message = message; self.code = code }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func get() -> Value? { lock.withLock { value } }
}

private func hash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
}

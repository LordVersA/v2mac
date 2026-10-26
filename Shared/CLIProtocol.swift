import Foundation

@objc protocol V2MacCLIProtocol {
    func request(_ json: String, reply: @escaping @Sendable (String) -> Void)
}

enum V2MacCLIIdentity {
    #if DEBUG
    static let endpointName = "cli-v1-dev.endpoint"
    static let appIdentifier = "io.github.lordversa.v2mac.dev"
    static let cliIdentifier = "io.github.lordversa.v2mac.dev.cli"
    static let dataFolder = "v2mac-dev"
    #else
    static let endpointName = "cli-v1.endpoint"
    static let appIdentifier = "io.github.lordversa.v2mac"
    static let cliIdentifier = "io.github.lordversa.v2mac.cli"
    static let dataFolder = "v2mac"
    #endif

    static var endpointURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataFolder, isDirectory: true)
            .appendingPathComponent(endpointName)
    }
}

struct CLIWireRequest: Codable {
    var apiVersion = 1
    var arguments: [String]
    var stdin: String?
    var clientHash: String
}

struct CLIWireResponse: Codable {
    var apiVersion = 1
    var ok: Bool
    var command: String
    var revision: String?
    var data: String?
    var warnings: [String] = []
    var error: CLIWireError?
    var appHash: String

    private enum CodingKeys: String, CodingKey { case apiVersion, ok, command, revision, data, warnings, error, appHash }

    init(apiVersion: Int = 1, ok: Bool, command: String, revision: String? = nil, data: String? = nil,
         warnings: [String] = [], error: CLIWireError? = nil, appHash: String) {
        self.apiVersion = apiVersion; self.ok = ok; self.command = command; self.revision = revision
        self.data = data; self.warnings = warnings; self.error = error; self.appHash = appHash
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try values.decode(Int.self, forKey: .apiVersion)
        ok = try values.decode(Bool.self, forKey: .ok)
        command = try values.decode(String.self, forKey: .command)
        revision = try values.decodeIfPresent(String.self, forKey: .revision)
        data = try values.decodeIfPresent(String.self, forKey: .data)
        warnings = try values.decode([String].self, forKey: .warnings)
        error = try values.decodeIfPresent(CLIWireError.self, forKey: .error)
        appHash = try values.decode(String.self, forKey: .appHash)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(apiVersion, forKey: .apiVersion); try values.encode(ok, forKey: .ok)
        try values.encode(command, forKey: .command); try values.encode(warnings, forKey: .warnings)
        if let revision { try values.encode(revision, forKey: .revision) } else { try values.encodeNil(forKey: .revision) }
        if let data { try values.encode(data, forKey: .data) } else { try values.encodeNil(forKey: .data) }
        if let error { try values.encode(error, forKey: .error) } else { try values.encodeNil(forKey: .error) }
        try values.encode(appHash, forKey: .appHash)
    }
}

struct CLIWireError: Codable {
    var id: String
    var message: String
    var exitCode: Int32
}

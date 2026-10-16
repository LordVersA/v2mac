import CryptoKit
import Foundation

/// A Cloudflare WARP device registered for MASQUE (spec 9.10). It holds the device's private key
/// and token, so the app keeps it in its selected secret store.
public struct WarpAccount: Codable, Sendable, Hashable {
    public var deviceID: String
    public var token: String
    /// The device's ECDSA P-256 key, PKCS #8 in base64.
    public var privateKey: String
    /// The key the WARP endpoint presents, PEM; Xray pins it.
    public var endpointPublicKey: String
    public var endpointV4: String
    public var endpointV6: String
    /// The tunnel's own addresses.
    public var addressV4: String
    public var addressV6: String
    public var accountID: String
    /// "free", "limited" (WARP+ with a data allowance), "unlimited" (WARP+ subscription), "team"…
    public var accountType: String
    /// The account's own license key: entering it on another device joins that device to the account.
    public var license: String
    /// WARP+ data left, in bytes.
    public var premiumData: Int64

    /// Cloudflare's `warp_plus` flag is true on free accounts too, so only the type says.
    public var isPlus: Bool { ["limited", "unlimited"].contains(accountType.lowercased()) }
}

public enum WarpError: Error, Sendable, Equatable, LocalizedError {
    /// The messages Cloudflare sent back, or the HTTP status when it sent none.
    case api(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .api(let message): String(localized: "Cloudflare refused: \(message)")
        case .badResponse: String(localized: "Cloudflare sent an answer V2Mac does not understand.")
        }
    }
}

/// The calls the WARP apps make to `api.cloudflareclient.com`. Cloudflare does not document them;
/// they follow the open-source clients (wgcf, usque) and may change.
public struct WarpClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.cloudflareclient.com/v0a4471")!
    public static let terms = URL(string: "https://www.cloudflare.com/application/terms/")!
    /// The SNI the WARP MASQUE endpoints answer to.
    public static let serverName = "consumer-masque.cloudflareclient.com"

    let baseURL: URL
    let session: URLSession

    public init(route: FetchRoute = .direct, baseURL: URL = defaultBaseURL) {
        self.baseURL = baseURL
        session = SessionFactory.make(route: route, timeout: 20)
    }

    /// Registers a new free device and switches it to MASQUE with a fresh key.
    public func register() async throws -> WarpAccount {
        let placeholderKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let tos = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
        let created: Registration = try await send("POST", "reg", body: [
            "key": placeholderKey, "install_id": "", "fcm_token": "", "tos": tos, "model": "PC",
            "serial_number": (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined(),
            "os_version": "", "key_type": "curve25519", "tunnel_type": "wireguard", "locale": "en_US",
        ], token: nil)
        guard let token = created.token else { throw WarpError.badResponse }
        let key = P256.Signing.PrivateKey()
        let enrolled: Registration = try await send("PATCH", "reg/\(created.id)", body: [
            "key": key.publicKey.derRepresentation.base64EncodedString(), "key_type": "secp256r1", "tunnel_type": "masque",
        ], token: token)
        return try Self.account(from: enrolled, token: token, privateKey: key.derRepresentation.base64EncodedString())
    }

    /// The account as Cloudflare has it now: type, WARP+ data, license.
    public func refresh(_ account: WarpAccount) async throws -> WarpAccount {
        let info: Registration.Account = try await send("GET", "reg/\(account.deviceID)/account", body: nil, token: account.token)
        var updated = account
        updated.apply(info)
        return updated
    }

    /// Joins the device to the account a license key belongs to, for example a WARP+ one.
    public func setLicense(_ license: String, on account: WarpAccount) async throws -> WarpAccount {
        let _: Registration.Account = try await send("PUT", "reg/\(account.deviceID)/account", body: ["license": license], token: account.token)
        return try await refresh(account)
    }

    /// Removes the device from Cloudflare.
    public func delete(_ account: WarpAccount) async throws {
        let _: Empty = try await send("DELETE", "reg/\(account.deviceID)", body: nil, token: account.token)
    }

    static func account(from r: Registration, token: String, privateKey: String) throws -> WarpAccount {
        guard let peer = r.config?.peers.first, let addresses = r.config?.interface.addresses else { throw WarpError.badResponse }
        var account = WarpAccount(
            deviceID: r.id, token: token, privateKey: privateKey, endpointPublicKey: peer.public_key,
            endpointV4: host(of: peer.endpoint.v4 ?? ""), endpointV6: host(of: peer.endpoint.v6 ?? ""),
            addressV4: addresses.v4 ?? "", addressV6: addresses.v6 ?? "",
            accountID: "", accountType: "", license: "", premiumData: 0
        )
        if let info = r.account { account.apply(info) }
        guard !account.endpointV4.isEmpty || !account.endpointV6.isEmpty else { throw WarpError.badResponse }
        return account
    }

    /// `162.159.198.1:0` → `162.159.198.1`, `[2606:4700:103::1]:0` → `2606:4700:103::1`.
    static func host(of endpoint: String) -> String {
        if endpoint.hasPrefix("["), let end = endpoint.firstIndex(of: "]") { return String(endpoint[endpoint.index(after: endpoint.startIndex)..<end]) }
        guard endpoint.filter({ $0 == ":" }).count == 1, let colon = endpoint.firstIndex(of: ":") else { return endpoint }
        return String(endpoint[..<colon])
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: String]?, token: String?) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("WARP for Android", forHTTPHeaderField: "User-Agent")
        request.setValue("a-6.35-4471", forHTTPHeaderField: "CF-Client-Version")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let messages = (try? JSONDecoder().decode(Failure.self, from: data))?.errors.map(\.message) ?? []
            throw WarpError.api(messages.isEmpty ? "HTTP \(status)" : messages.joined(separator: "; "))
        }
        if T.self == Empty.self { return Empty() as! T }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw WarpError.badResponse }
    }
}

extension WarpAccount {
    mutating func apply(_ info: Registration.Account) {
        accountID = info.id ?? accountID
        accountType = info.account_type ?? accountType
        license = info.license ?? license
        premiumData = info.premium_data ?? premiumData
    }

    /// The `masque` outbound that connects to WARP with this device's key.
    public var outbound: JSONValue {
        let address = [addressV4, addressV6].filter { !$0.isEmpty }.map { JSONValue.string($0) }
        return [
            "protocol": "masque",
            "settings": ["address": .string(endpointV4.isEmpty ? endpointV6 : endpointV4), "port": 443],
            "streamSettings": [
                "network": "masque",
                "security": "tls",
                "tlsSettings": ["serverName": .string(WarpClient.serverName)],
                "masqueSettings": ["warp": [
                    "privateKey": .string(privateKey),
                    "publicKey": .string(endpointPublicKey),
                    "address": .array(address),
                ]],
            ],
        ]
    }

    /// WARP as a server of its own in the list.
    public var profile: ParsedProfile {
        ParsedProfile(
            name: isPlus ? "Cloudflare WARP+" : "Cloudflare WARP", kind: .outbound, protocolName: "masque",
            address: endpointV4.isEmpty ? endpointV6 : endpointV4, port: 443, transport: "masque", security: "tls", config: outbound
        )
    }
}

// Cloudflare's JSON, with its own key names.
struct Registration: Decodable {
    struct Account: Decodable {
        var id: String?
        var account_type: String?
        var license: String?
        var premium_data: Int64?
    }
    struct Config: Decodable {
        struct Peer: Decodable {
            struct Endpoint: Decodable { var v4: String?; var v6: String? }
            var public_key: String
            var endpoint: Endpoint
        }
        struct Interface: Decodable {
            struct Addresses: Decodable { var v4: String?; var v6: String? }
            var addresses: Addresses
        }
        var peers: [Peer]
        var interface: Interface
    }
    var id: String
    var token: String?
    var account: Account?
    var config: Config?
}

private struct Failure: Decodable {
    struct Message: Decodable { var message: String }
    var errors: [Message]
}

private struct Empty: Decodable {}

import CryptoKit
import Foundation
import Network
import os
import Security

/// Spec 8.5: servers whose link says `allowInsecure`. Xray no longer takes that flag, so the
/// stored outbound keeps it as a marker and it never reaches the core: either it is replaced by
/// a pin of the certificate the server presents now, or it is dropped.
public enum InsecureTLS {
    static let flag = "allowInsecure"
    static let pin = "pinnedPeerCertSha256"

    private static func tls(of outbound: JSONValue) -> JSONValue? {
        outbound["streamSettings"]?["tlsSettings"]
    }

    private static func setting(tls: JSONValue, in outbound: JSONValue) -> JSONValue {
        guard let stream = outbound["streamSettings"] else { return outbound }
        return outbound.setting("streamSettings", to: stream.setting("tlsSettings", to: tls))
    }

    public static func isRequested(by outbound: JSONValue) -> Bool {
        tls(of: outbound)?[flag]?.boolValue == true
    }

    /// The outbound as Xray accepts it, with its certificate checked the normal way.
    public static func stripping(_ outbound: JSONValue) -> JSONValue {
        guard let tls = tls(of: outbound), tls[flag] != nil else { return outbound }
        return setting(tls: tls.removing(flag), in: outbound)
    }

    /// Asks the server for its certificate and pins it, which is what the flag meant: accept
    /// whatever the server shows. When the server cannot be asked the flag is only dropped.
    public static func pinning(_ outbound: JSONValue, timeout: TimeInterval = 4) async -> JSONValue {
        guard isRequested(by: outbound), let tls = tls(of: outbound), tls[pin] == nil,
              let host = outbound["settings"]?["address"]?.stringValue,
              let port = outbound["settings"]?["port"]?.intValue
        else { return stripping(outbound) }
        let alpn = tls["alpn"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let quic = outbound["streamSettings"]?["network"]?.stringValue == "hysteria" || alpn == ["h3"]
        let hash = await leafCertificateHash(
            host: host, port: port, serverName: tls["serverName"]?.stringValue, alpn: alpn, quic: quic, timeout: timeout
        )
        guard let hash else { return stripping(outbound) }
        return setting(tls: tls.removing(flag).setting(pin, to: .string(hash)), in: outbound)
    }

    public static func pinning(_ outbounds: [JSONValue], timeout: TimeInterval = 4) async -> [JSONValue] {
        await withTaskGroup(of: (Int, JSONValue).self) { group in
            var result = outbounds
            for (index, outbound) in outbounds.enumerated() where isRequested(by: outbound) {
                group.addTask { (index, await pinning(outbound, timeout: timeout)) }
            }
            for await (index, outbound) in group { result[index] = outbound }
            return result
        }
    }

    /// SHA-256 (hex) of the leaf certificate's DER bytes, the form `pinnedPeerCertSha256` takes.
    /// The handshake is refused as soon as the certificate has been seen.
    public static func leafCertificateHash(
        host: String, port: Int, serverName: String?, alpn: [String], quic: Bool, timeout: TimeInterval
    ) async -> String? {
        guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let queue = DispatchQueue(label: "v2mac.certificate")
        let state = OSAllocatedUnfairLock(initialState: (hash: String?.none, finished: false))

        func configure(_ options: sec_protocol_options_t) {
            if let serverName { sec_protocol_options_set_tls_server_name(options, serverName) }
            sec_protocol_options_set_verify_block(options, { _, trust, complete in
                let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
                if let leaf = chain?.first {
                    let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                    let hex = digest.map { String(format: "%02x", $0) }.joined()
                    state.withLock { $0.hash = hex }
                }
                complete(false)
            }, queue)
        }

        let parameters: NWParameters
        if quic {
            let options = NWProtocolQUIC.Options(alpn: alpn.isEmpty ? ["h3"] : alpn)
            configure(options.securityProtocolOptions)
            parameters = NWParameters(quic: options)
        } else {
            let options = NWProtocolTLS.Options()
            for name in alpn { sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, name) }
            configure(options.securityProtocolOptions)
            parameters = NWParameters(tls: options)
        }
        // Never through a tunnel (TUN mode): the server is asked directly, as the core dials it.
        parameters.prohibitedInterfaceTypes = [.other]

        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        return await withCheckedContinuation { continuation in
            @Sendable func finish() {
                let hash: String?? = state.withLock { current in
                    if current.finished { return nil }
                    current.finished = true
                    return .some(current.hash)
                }
                guard let hash else { return }
                connection.cancel()
                continuation.resume(returning: hash)
            }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready, .failed, .cancelled, .waiting: finish()
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }
}

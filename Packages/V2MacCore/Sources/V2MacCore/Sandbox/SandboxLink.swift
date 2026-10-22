import Foundation

/// Messages between V2Mac and the sandbox helper over the socketpair it is launched with
/// (sandbox plan §2). Each frame is a 4-byte big-endian length followed by that many bytes of JSON.
/// The helper is downloaded code, so V2Mac treats what it sends as untrusted: frames are size-limited
/// and anything that does not decode is a closed link.
public enum SandboxLink {
    /// Bumped on an incompatible change; V2Mac and the sandbox it pins always match.
    public static let version = 1
    public static let maxFrame = 1 << 20

    public struct Server: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// V2Mac → helper.
    public enum ToHelper: Codable, Sendable, Equatable {
        case hello(version: Int, ramCapMB: Int)
        case settings(ramCapMB: Int)
        case servers([Server], active: String?)
        case outbound(id: String, json: String?)
        case downloaded(request: Int, path: String?)
        case openWindow
        /// Asks whether sandbox apps are open; answered with `quitReply`.
        case quitRequest
        /// Shut everything down and exit.
        case quit
    }

    /// Helper → V2Mac.
    public enum ToApp: Codable, Sendable, Equatable {
        case hello(version: Int)
        /// "stopped", "booting", "running" or "stopping".
        case vmState(String)
        case outbound(id: String)
        case download(request: Int, url: URL, sha256: String)
        case notice(kind: String, text: String)
        case quitReply(appsOpen: Bool)
    }

    public struct FrameTooLarge: Error, Equatable {}

    public static func frame(_ message: some Encodable) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= maxFrame else { throw FrameTooLarge() }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Collects bytes as they arrive and hands out whole messages.
    public struct Reader<Message: Decodable>: Sendable {
        private var buffer = Data()
        public init() {}

        /// Returns every complete message in `buffer` after appending `bytes`. Throws on an oversized
        /// length or a body that is not a `Message`; the link must be closed then.
        public mutating func feed(_ bytes: Data) throws -> [Message] {
            buffer.append(bytes)
            var messages: [Message] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard length <= SandboxLink.maxFrame else { throw FrameTooLarge() }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.dropFirst(4).prefix(length)
                messages.append(try JSONDecoder().decode(Message.self, from: Data(body)))
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return messages
        }
    }
}

import Foundation

@objc(V2MacPrivilegedHelperProtocol) protocol PrivilegedHelperProtocol {
    func startSession(port: Int, interfaceName: String, state: Data, withReply reply: @escaping @Sendable (String?) -> Void)
    func updateSession(state: Data, withReply reply: @escaping @Sendable (String?) -> Void)
    func stopSession(withReply reply: @escaping @Sendable (String?) -> Void)
}

enum PrivilegedHelperIdentity {
    #if DEBUG
    static let appIdentifier = "io.github.lordversa.v2mac.dev"
    static let dataFolderName = "v2mac-dev"
    #else
    static let appIdentifier = "io.github.lordversa.v2mac"
    static let dataFolderName = "v2mac"
    #endif
    static let serviceName = appIdentifier + ".privileged"
    static let plistName = serviceName + ".plist"
}

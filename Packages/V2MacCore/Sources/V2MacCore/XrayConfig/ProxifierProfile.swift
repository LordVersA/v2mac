import Foundation

/// A Proxifier profile (`.ppx`) read as V2Mac rules (spec 8.6). Rules to a proxy on this Mac become
/// Proxy rules; rules to any other proxy or a chain are skipped, as V2Mac has only its own server.
public struct ProxifierProfile: Sendable, Equatable {
    public var rules: [CustomRule] = []
    /// Names of the rules left out.
    public var skipped: [String] = []
    public var blockQUIC = false

    public init(data: Data) throws {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.sawProfile else { throw CocoaError(.fileReadCorruptFile) }
        blockQUIC = reader.blockUDP443
        if !reader.exclusions.isEmpty {
            rules.append(CustomRule(name: String(localized: "Proxifier exclusions"), action: .direct, hosts: Self.lines(reader.exclusions)))
        }
        for rule in reader.rules {
            let action: CustomRule.Action? = switch rule.action.lowercased() {
            case "direct": .direct
            case "block": .block
            case "proxy": reader.localProxies.contains(rule.actionValue) ? .proxy : nil
            default: nil
            }
            // The default rule (no apps, no hosts) is the routing mode's job.
            if rule.apps.isEmpty && rule.targets.isEmpty { continue }
            guard let action else { skipped.append(rule.name); continue }
            rules.append(CustomRule(name: rule.name, action: action, apps: Self.lines(rule.apps), hosts: Self.lines(rule.targets), enabled: rule.enabled))
        }
    }

    /// Proxifier separates entries with `;`; keep one per line, minus its `%ComputerName%`-style macros.
    static func lines(_ text: String) -> String {
        text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%") }.joined(separator: "\n")
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Rule { var name = "", enabled = true, apps = "", targets = "", action = "", actionValue = "" }
        var rules: [Rule] = []
        var exclusions = ""
        var blockUDP443 = false
        var sawProfile = false
        /// Ids of proxies at 127.0.0.1 or localhost: V2Mac's own port.
        var localProxies: Set<String> = []
        private var rule: Rule?
        private var proxyID: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "ProxifierProfile": sawProfile = true
            case "BlockUDP443": blockUDP443 = attributes["enabled"] == "true"
            case "Rule": rule = Rule(enabled: attributes["enabled"] != "false")
            case "Action": rule?.action = attributes["type"] ?? ""
            case "Proxy": proxyID = attributes["id"]
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "Name": rule?.name = value
            case "Applications": rule?.apps = value
            case "Targets": rule?.targets = value
            case "Action": rule?.actionValue = value
            case "Rule": if let rule { rules.append(rule) }; rule = nil
            case "ExclusionList": exclusions = value
            case "Address": if let proxyID, ["127.0.0.1", "localhost", "::1"].contains(value.lowercased()) { localProxies.insert(proxyID) }
            case "Proxy": proxyID = nil
            default: break
            }
            text = ""
        }
    }
}

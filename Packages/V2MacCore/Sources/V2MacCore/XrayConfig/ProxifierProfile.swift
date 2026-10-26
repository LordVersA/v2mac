import Foundation

/// A Proxifier profile (`.ppx`) read as V2Mac rules (spec 8.6). Rules to a proxy on this Mac become
/// Proxy rules; rules to any other proxy or a chain are skipped, as V2Mac has only its own server.
/// A rule's ports become an "Only when" condition.
public struct ProxifierProfile: Sendable, Equatable {
    public var rules: [Rule] = []
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
            rules.append(RuleImport.rule(name: String(localized: "Proxifier exclusions"), action: .direct, apps: [], hosts: Self.entries(reader.exclusions), only: .init()))
        }
        for rule in reader.rules {
            let action: Rule.Action? = switch rule.action.lowercased() {
            case "direct": .direct
            case "block": .block
            case "proxy": reader.localProxies.contains(rule.actionValue) ? .proxy : nil
            default: nil
            }
            // The default rule (no apps, no hosts) is the routing mode's job.
            if rule.apps.isEmpty && rule.targets.isEmpty { continue }
            let ports = Self.entries(rule.ports).joined(separator: ",")
            guard let action, ports.isEmpty || Rule.OnlyWhen.validPorts(ports) else { skipped.append(rule.name); continue }
            var made = RuleImport.rule(name: rule.name, action: action, apps: Rule.appEntries(Self.entries(rule.apps).joined(separator: "\n")),
                                       hosts: Self.entries(rule.targets), only: .init(ports: ports))
            made.enabled = rule.enabled
            rules.append(made)
        }
    }

    /// Proxifier separates entries with `;`; its `%ComputerName%`-style macros are left out.
    static func entries(_ text: String) -> [String] {
        text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("%") }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Entry { var name = "", enabled = true, apps = "", targets = "", ports = "", action = "", actionValue = "" }
        var rules: [Entry] = []
        var exclusions = ""
        var blockUDP443 = false
        var sawProfile = false
        /// Ids of proxies at 127.0.0.1 or localhost: V2Mac's own port.
        var localProxies: Set<String> = []
        private var rule: Entry?
        private var proxyID: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "ProxifierProfile": sawProfile = true
            case "BlockUDP443": blockUDP443 = attributes["enabled"] == "true"
            case "Rule": rule = Entry(enabled: attributes["enabled"] != "false")
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
            case "Ports": rule?.ports = value
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

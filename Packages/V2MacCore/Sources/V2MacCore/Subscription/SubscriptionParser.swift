import Foundation

public enum SubscriptionParser {
    // MARK: Entry point

    public static func parse(body: Data, headers: [String: String] = [:]) throws -> SubscriptionResult {
        let text = String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
        return try parse(text: text, headers: headers)
    }

    public static func parse(text raw: String, headers: [String: String] = [:]) throws -> SubscriptionResult {
        let normalised = normalise(raw)
        var metadata = parseMetadata(headers: headers)

        let content: String
        if isClash(normalised) { throw SubscriptionError.unsupportedFormat("Clash") }
        if looksStructured(normalised) {
            content = normalised
        } else if hasKnownScheme(normalised) {
            content = normalised
        } else if let decoded = Base64Tolerant.decodeString(normalised).map(normalise),
                  looksStructured(decoded) || hasKnownScheme(decoded) {
            content = decoded
        } else {
            throw SubscriptionError.unrecognisedFormat
        }

        mergeBodyDirectives(from: normalised, into: &metadata)
        if content != normalised { mergeBodyDirectives(from: content, into: &metadata) }

        let (profiles, skipped): ([ParsedProfile], [SkippedEntry])
        if looksStructured(content) {
            (profiles, skipped) = try parseJSON(content)
        } else {
            (profiles, skipped) = parseLinks(content)
        }
        guard !profiles.isEmpty else { throw SubscriptionError.noServers(skipped: skipped.count) }
        return SubscriptionResult(profiles: profiles, skipped: skipped, metadata: metadata)
    }

    // MARK: Detection

    static func normalise(_ s: String) -> String {
        var t = s
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksStructured(_ s: String) -> Bool {
        s.hasPrefix("[") || s.hasPrefix("{")
    }

    static func hasKnownScheme(_ s: String) -> Bool {
        s.split(separator: "\n").contains { ShareLinkParser.knownScheme(of: $0.trimmingCharacters(in: .whitespaces)) != nil }
    }

    static func isClash(_ s: String) -> Bool {
        s.split(separator: "\n", omittingEmptySubsequences: true).contains {
            $0.hasPrefix("proxies:") || $0.hasPrefix("proxy-groups:")
        }
    }

    // MARK: Link lists

    static func parseLinks(_ text: String) -> ([ParsedProfile], [SkippedEntry]) {
        var profiles: [ParsedProfile] = []
        var skipped: [SkippedEntry] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            guard line.contains("://") else { continue }
            do {
                profiles.append(try ShareLinkParser.parse(line))
            } catch let skip as LinkSkip {
                skipped.append(SkippedEntry(index: offset + 1, reason: skip.reason))
            } catch {
                skipped.append(SkippedEntry(index: offset + 1, reason: error.localizedDescription))
            }
        }
        return (profiles, skipped)
    }

    // MARK: JSON bodies

    static func parseJSON(_ text: String) throws -> ([ParsedProfile], [SkippedEntry]) {
        var profiles: [ParsedProfile] = []
        var skipped: [SkippedEntry] = []
        guard let root = try? JSONValue.parse(Data(text.utf8)) else {
            // Several configs pasted one after another, without an enclosing array.
            let parts = splitTopLevelObjects(text)
            guard parts.count > 1 else { throw SubscriptionError.unrecognisedFormat }
            for (i, part) in parts.enumerated() {
                do {
                    profiles.append(try JSONProfile.make(from: try JSONValue.parse(Data(part.utf8)), number: i + 1))
                } catch let skip as LinkSkip {
                    skipped.append(SkippedEntry(index: i + 1, reason: skip.reason))
                } catch {
                    skipped.append(SkippedEntry(index: i + 1, reason: "invalid JSON"))
                }
            }
            return (profiles, skipped)
        }

        func add(_ value: JSONValue, number: Int) {
            do {
                profiles.append(try JSONProfile.make(from: value, number: number))
            } catch let skip as LinkSkip {
                skipped.append(SkippedEntry(index: number, reason: skip.reason))
            } catch {
                skipped.append(SkippedEntry(index: number, reason: error.localizedDescription))
            }
        }

        switch root {
        case .array(let items):
            for (i, item) in items.enumerated() { add(item, number: i + 1) }
        case .object:
            add(root, number: 1)
        default:
            throw SubscriptionError.unrecognisedFormat
        }
        return (profiles, skipped)
    }

    /// Cuts `{…} {…}` into its objects by brace depth, ignoring braces inside strings.
    /// Text outside any object (whitespace, commas) is dropped.
    static func splitTopLevelObjects(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        for index in text.indices {
            let c = text[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                if depth > 0 { inString = true }
            case "{", "[":
                if depth == 0 { start = index }
                depth += 1
            case "}", "]":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let begin = start {
                    parts.append(String(text[begin...index]))
                    start = nil
                }
            default:
                break
            }
        }
        return parts
    }

    // MARK: Metadata

    static func parseMetadata(headers rawHeaders: [String: String]) -> SubscriptionMetadata {
        var headers: [String: String] = [:]
        for (k, v) in rawHeaders { headers[k.lowercased()] = v }
        var m = SubscriptionMetadata()

        if let title = headers["profile-title"].flatMap(decodeTitle) {
            m.title = title
        } else if let name = headers["content-disposition"].flatMap(filename(from:)) {
            m.title = name
        }
        if let h = headers["profile-update-interval"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), h > 0 {
            m.updateIntervalHours = h
        }
        if let info = headers["subscription-userinfo"] {
            var fields: [String: Int64] = [:]
            for part in info.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, let n = Int64(kv[1].trimmingCharacters(in: .whitespaces)) else { continue }
                fields[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = n
            }
            m.uploadBytes = fields["upload"]
            m.downloadBytes = fields["download"]
            if fields["upload"] != nil || fields["download"] != nil {
                m.usedBytes = (fields["upload"] ?? 0) + (fields["download"] ?? 0)
            }
            if let total = fields["total"], total > 0 { m.totalBytes = total }
            if let expire = fields["expire"], expire > 0 { m.expiresAt = Date(timeIntervalSince1970: TimeInterval(expire)) }
        }
        m.supportURL = headers["support-url"].flatMap(webLink)
        m.webPageURL = headers["profile-web-page-url"].flatMap(webLink)
        return m
    }

    private static func webLink(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Accepts `#profile-title:` / `#profile-update-interval:` lines when headers did not supply them.
    static func mergeBodyDirectives(from text: String, into m: inout SubscriptionMetadata) {
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("#") else { continue }
            let body = l.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].lowercased()
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "profile-title", m.title == nil { m.title = decodeTitle(value) }
            if key == "profile-update-interval", m.updateIntervalHours == nil, let h = Int(value), h > 0 {
                m.updateIntervalHours = h
            }
        }
    }

    static func decodeTitle(_ value: String) -> String? {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.lowercased().hasPrefix("base64:") {
            v = Base64Tolerant.decodeString(String(v.dropFirst("base64:".count))) ?? v
        } else if v.contains("%") {
            v = v.removingPercentEncoding ?? v
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static func filename(from disposition: String) -> String? {
        for part in disposition.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let lower = part.lowercased()
            guard lower.hasPrefix("filename") , let eq = part.firstIndex(of: "=") else { continue }
            var value = String(part[part.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if lower.hasPrefix("filename*"), let r = value.range(of: "''") {
                value = String(value[r.upperBound...])
            }
            value = value.removingPercentEncoding ?? value
            if !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - Raw Xray JSON entries

enum JSONProfile {
    private static let nonProxyProtocols: Set<String> = ["freedom", "blackhole", "dns", "loopback"]

    static func make(from value: JSONValue, number: Int) throws -> ParsedProfile {
        guard case .object = value else { throw LinkSkip("not a JSON object") }
        if let outbounds = value["outbounds"]?.arrayValue {
            if outbounds.contains(where: { $0["type"] != nil && $0["protocol"] == nil }) {
                throw LinkSkip("sing-box configs are not supported")
            }
            return custom(value, outbounds: outbounds, number: number)
        }
        if let proto = value["protocol"]?.stringValue {
            return outbound(value, protocolName: proto)
        }
        throw LinkSkip("JSON entry has neither \"outbounds\" nor \"protocol\"")
    }

    private static func custom(_ config: JSONValue, outbounds: [JSONValue], number: Int) -> ParsedProfile {
        let proxy = outbounds.first { !nonProxyProtocols.contains($0["protocol"]?.stringValue ?? "") } ?? outbounds.first
        let (address, port) = endpoint(of: proxy)
        let remarks = config["remarks"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedProfile(
            name: (remarks?.isEmpty == false ? remarks : nil) ?? "Config \(number)",
            kind: .custom,
            protocolName: "custom",
            address: address,
            port: port,
            transport: "",
            security: "",
            config: config
        )
    }

    private static func outbound(_ value: JSONValue, protocolName: String) -> ParsedProfile {
        let (address, port) = endpoint(of: value)
        let stream = value["streamSettings"]
        let network = (stream?["network"]?.stringValue ?? "raw").lowercased()
        let transport = network == "tcp" ? "raw" : (network == "splithttp" ? "xhttp" : network)
        let security = stream?["security"]?.stringValue ?? "none"
        let tag = value["tag"]?.stringValue ?? value["remarks"]?.stringValue
        let name = (tag?.isEmpty == false ? tag : nil) ?? "\(address):\(port)"
        return ParsedProfile(
            name: name,
            kind: .outbound,
            protocolName: protocolName,
            address: address,
            port: port,
            transport: transport,
            security: security,
            config: value.removing("tag").removing("remarks")
        )
    }

    /// Best-effort server address/port from flat settings, `vnext` or `servers`.
    private static func endpoint(of outbound: JSONValue?) -> (String, Int) {
        guard let settings = outbound?["settings"] else { return ("", 0) }
        let node = settings["vnext"]?[0] ?? settings["servers"]?[0] ?? settings
        let address = node["address"]?.stringValue ?? ""
        let port = node["port"]?.intValue ?? 0
        return (address, port)
    }
}

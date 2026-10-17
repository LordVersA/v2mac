import Foundation

/// The part of YAML that Clash and Mihomo configs use, read into a `JSONValue`: block mappings and
/// sequences, flow `{}` and `[]`, quoted and plain scalars, comments.
/// shortcut: no anchors, tags or multi-line scalars; add them if real configs need them.
enum MiniYAML {
    static func parse(_ text: String) -> JSONValue {
        var lines: [(indent: Int, text: String)] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let body = stripComment(String(raw))
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" { continue }
            lines.append((body.prefix { $0 == " " }.count, trimmed))
        }
        var index = 0
        return block(&lines, &index, indent: lines.first?.indent ?? 0)
    }

    /// One block whose lines all start at `indent`.
    private static func block(_ lines: inout [(indent: Int, text: String)], _ index: inout Int, indent: Int) -> JSONValue {
        guard index < lines.count else { return .null }
        if lines[index].text == "-" || lines[index].text.hasPrefix("- ") {
            var items: [JSONValue] = []
            while index < lines.count, lines[index].indent == indent, lines[index].text == "-" || lines[index].text.hasPrefix("- ") {
                let rest = String(lines[index].text.dropFirst()).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    index += 1
                    items.append(index < lines.count && lines[index].indent > indent ? block(&lines, &index, indent: lines[index].indent) : .null)
                } else if keyValue(rest) != nil, !rest.hasPrefix("{"), !rest.hasPrefix("[") {
                    // `- key: value` starts a mapping whose other keys line up with `key`.
                    let inner = indent + (lines[index].text.count - rest.count)
                    lines[index] = (inner, rest)
                    items.append(block(&lines, &index, indent: inner))
                } else {
                    items.append(scalar(rest))
                    index += 1
                }
            }
            return .array(items)
        }
        var object: [String: JSONValue] = [:]
        while index < lines.count, lines[index].indent == indent, let (key, value) = keyValue(lines[index].text) {
            index += 1
            if !value.isEmpty {
                object[key] = scalar(value)
            } else if index < lines.count, lines[index].indent > indent || (lines[index].indent == indent && lines[index].text.hasPrefix("- ")) {
                object[key] = block(&lines, &index, indent: lines[index].indent)
            } else {
                object[key] = .null
            }
        }
        // A line at a deeper indent that belongs to nothing: skip it rather than loop.
        if object.isEmpty { index += 1 }
        return .object(object)
    }

    /// `key: value` outside quotes and brackets; the value may be empty.
    private static func keyValue(_ text: String) -> (String, String)? {
        var quote: Character?
        var depth = 0
        for i in text.indices {
            let c = text[i]
            if let q = quote { if c == q { quote = nil }; continue }
            switch c {
            case "\"", "'": quote = c
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            case ":" where depth == 0:
                let next = text.index(after: i)
                guard next == text.endIndex || text[next] == " " else { continue }
                let key = unquote(text[..<i].trimmingCharacters(in: .whitespaces))
                return key.isEmpty ? nil : (key, text[next...].trimmingCharacters(in: .whitespaces))
            default: break
            }
        }
        return nil
    }

    private static func scalar(_ text: String) -> JSONValue {
        var reader = FlowReader(text: Array(text))
        return reader.value(plainStops: [])
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return text }
        let inner = String(text.dropFirst().dropLast())
        return first == "'" ? inner.replacingOccurrences(of: "''", with: "'") : inner.replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Drops a ` #` comment that is not inside quotes.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for i in line.indices {
            let c = line[i]
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { if previous == " " || previous == "[" || previous == "{" || previous == "," || previous == ":" { quote = c } }
            else if c == "#", previous == " " || i == line.startIndex { return String(line[..<i]) }
            previous = c
        }
        return line
    }

    /// Reads flow collections (`{a: 1, b: [x, y]}`) and scalars.
    private struct FlowReader {
        let text: [Character]
        var at = 0

        mutating func skipSpaces() { while at < text.count, text[at] == " " { at += 1 } }

        mutating func value(plainStops: Set<Character>) -> JSONValue {
            skipSpaces()
            guard at < text.count else { return .null }
            switch text[at] {
            case "{":
                at += 1
                var object: [String: JSONValue] = [:]
                while true {
                    skipSpaces()
                    if at >= text.count { break }
                    if text[at] == "}" { at += 1; break }
                    if text[at] == "," { at += 1; continue }
                    guard case .string(let key) = value(plainStops: [":", ",", "}"]) else { break }
                    skipSpaces()
                    if at < text.count, text[at] == ":" { at += 1; object[key] = value(plainStops: [",", "}"]) }
                    else { object[key] = .null }
                }
                return .object(object)
            case "[":
                at += 1
                var items: [JSONValue] = []
                while true {
                    skipSpaces()
                    if at >= text.count { break }
                    if text[at] == "]" { at += 1; break }
                    if text[at] == "," { at += 1; continue }
                    items.append(value(plainStops: [",", "]"]))
                }
                return .array(items)
            case "\"", "'":
                let quote = text[at]
                at += 1
                var out = ""
                while at < text.count {
                    let c = text[at]
                    at += 1
                    if quote == "\"", c == "\\", at < text.count {
                        let e = text[at]
                        at += 1
                        out.append(e == "n" ? "\n" : e == "t" ? "\t" : e)
                    } else if c == quote {
                        if quote == "'", at < text.count, text[at] == "'" { out.append("'"); at += 1 } else { break }
                    } else {
                        out.append(c)
                    }
                }
                return .string(out)
            default:
                var out = ""
                while at < text.count {
                    let c = text[at]
                    // In flow context `:` ends a key only when a space or the end follows.
                    if plainStops.contains(c), c != ":" || at + 1 >= text.count || text[at + 1] == " " { break }
                    out.append(c)
                    at += 1
                }
                return plain(out.trimmingCharacters(in: .whitespaces))
            }
        }

        private func plain(_ s: String) -> JSONValue {
            switch s.lowercased() {
            case "true", "yes", "on": return .bool(true)
            case "false", "no", "off": return .bool(false)
            case "null", "~", "": return .null
            default: break
            }
            if let n = Double(s), s.first.map({ $0.isNumber || $0 == "-" }) == true, !s.contains("e"), !s.contains("E") { return .number(n) }
            return .string(s)
        }
    }
}

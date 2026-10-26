import CryptoKit
import Darwin
import Foundation
import Security
import SwiftData
import V2MacCore

@MainActor
final class CLIService: NSObject, NSXPCListenerDelegate, V2MacCLIProtocol {
    private weak var model: AppModel?
    private let listener = NSXPCListener.anonymous()
    private var appHash = ""

    init(model: AppModel) {
        self.model = model
        super.init()
        listener.delegate = self
        appHash = Self.hash(Bundle.main.executableURL!) ?? ""
        listener.resume()
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: listener.endpoint, requiringSecureCoding: true)
            try data.write(to: V2MacCLIIdentity.endpointURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: V2MacCLIIdentity.endpointURL.path)
        } catch {
            model.logs.append("[v2mac] Could not publish the CLI endpoint: \(error.localizedDescription)")
        }
    }

    deinit { try? FileManager.default.removeItem(at: V2MacCLIIdentity.endpointURL) }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard Self.validClient(pid: connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: V2MacCLIProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    nonisolated func request(_ json: String, reply: @escaping @Sendable (String) -> Void) {
        Task { @MainActor in
            guard let request = try? JSONDecoder().decode(CLIWireRequest.self, from: Data(json.utf8)), request.apiVersion == 1 else {
                reply(self.response(command: "", error: .init(id: "protocol_mismatch", message: "Unsupported or malformed CLI protocol.", exitCode: EX_DATAERR)))
                return
            }
            let expected = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/v2mac")
            guard request.clientHash == Self.hash(expected) else {
                reply(self.response(command: request.arguments.first ?? "", error: .init(id: "permission_denied", message: "The client is not this app's embedded CLI.", exitCode: EX_NOPERM)))
                return
            }
            reply(await self.execute(request))
        }
    }

    private func execute(_ request: CLIWireRequest) async -> String {
        let args = request.arguments.filter { $0 != "--json" }
        let command = args.prefix(3).joined(separator: " ")
        guard let model else { return response(command: command, error: internalError("The app is not ready.")) }
        do {
            if args.first == "version" {
                return response(command: "version", data: Prefs.appVersion)
            }
            if args.first == "status" {
                return response(command: "status", data: model.connection.isRunning ? "connected" : "disconnected")
            }
            if args.first == "connect" {
                guard model.connection.activeServer != nil else { throw CLIError("unavailable", "No active server is selected.", EX_UNAVAILABLE) }
                model.connection.connectActive()
                return response(command: "connect", data: "Connecting")
            }
            if args.first == "disconnect" {
                if model.connection.isRunning { model.connection.disconnect() }
                return response(command: "disconnect", data: "Disconnected")
            }
            guard args.first == "rules" else { throw CLIError("usage", "Unknown command. Run v2mac --help.", EX_USAGE) }
            await model.ruleCatalog.load()
            return try await rules(Array(args.dropFirst()), stdin: request.stdin, model: model)
        } catch let error as CLIError {
            return response(command: command, revision: revision(), error: .init(id: error.id, message: error.message, exitCode: error.code))
        } catch {
            return response(command: command, revision: revision(), error: internalError(error.localizedDescription))
        }
    }

    private func rules(_ args: [String], stdin: String?, model: AppModel) async throws -> String {
        guard let verb = args.first else { throw usage("Missing rules command.") }
        if verb == "profiles" { return try profiles(Array(args.dropFirst()), model: model) }
        if verb == "built-ins" { return try builtIns(Array(args.dropFirst()), model: model) }
        let profile = try selectedProfile(option("--profile", in: args))
        let current = rules(for: profile)

        switch verb {
        case "list":
            return response(command: "rules list", revision: revision(), data: render(current))
        case "show":
            let rule = try selectedRule(positionals(args).dropFirst().first, in: current)
            return response(command: "rules show", revision: revision(), data: json(rule))
        case "export":
            return response(command: "rules export", revision: revision(), data: Rule.encode(current))
        case "validate":
            let proposed = try readRules(file: option("--file", in: args), stdin: stdin)
            try validate(proposed, model: model)
            return response(command: "rules validate", revision: revision(), data: "Valid (\(proposed.count) rules)")
        case "targets":
            let targets = ((try? model.context.fetch(FetchDescriptor<Profile>())) ?? []).filter { !$0.isStale }.map { "server\t\($0.id)\t\($0.name)" }
                + ((try? model.context.fetch(FetchDescriptor<ServerGroup>())) ?? []).map { "group\t\($0.id)\t\($0.name)" }
            return response(command: "rules targets list", revision: revision(), data: targets.joined(separator: "\n"))
        case "templates":
            let words = positionals(args)
            if words.dropFirst().first == "list" { return response(command: "rules templates list", revision: revision(), data: RuleTemplate.all.map { "\($0.id.rawValue)\t\($0.name)" }.joined(separator: "\n")) }
            guard words.dropFirst().first == "create", words.count > 2,
                  let id = RuleTemplate.ID(rawValue: words[2]), let template = RuleTemplate.all.first(where: { $0.id == id }) else { throw usage("Use rules templates create TEMPLATE.") }
            let rule = template.rule(available: Set(model.ruleCatalog.geo.lists), installed: model.ruleCatalog.apps, regions: model.regionPacks.usableRoutes)
            return try mutate(command: "rules templates create", profile: profile, args: args, proposed: current + [rule], model: model, detail: rule.id.uuidString)
        case "tidy":
            let suggestions = TidyUp.suggestions(for: current, apps: model.ruleCatalog.apps)
            let operation = positionals(args).dropFirst().first
            if operation == "list" { return response(command: "rules tidy list", revision: revision(), data: suggestions.map { "\(tidyID($0))\t\(String(describing: $0.kind))" }.joined(separator: "\n")) }
            guard operation == "apply" else { throw usage("Use rules tidy list or apply.") }
            let wanted = Set(options("--id", in: args))
            guard !wanted.isEmpty else { throw usage("Select suggestions with --id.") }
            let chosen = suggestions.filter { wanted.contains(tidyID($0)) }
            guard chosen.count == wanted.count else { throw invalid("One or more Tidy Up IDs are stale or unknown.") }
            return try mutate(command: "rules tidy apply", profile: profile, args: args, proposed: TidyUp.apply(chosen, to: current), model: model)
        case "test":
            guard let host = option("--host", in: args) else { throw usage("rules test requires --host.") }
            let port = option("--port", in: args).flatMap(Int.init) ?? 443
            guard (1...65535).contains(port) else { throw invalid("Invalid port.") }
            let network = Rule.Network(rawValue: option("--network", in: args) ?? "tcp") ?? .tcp
            var custom = Prefs.customRules
            custom.rules = current
            custom.installedApps = model.ruleCatalog.apps
            custom.siteTags = model.ruleCatalog.geo.siteTags
            let query = RouteQuery(host: host, ips: options("--ip", in: args), port: port, network: network,
                                   process: option("--process", in: args), sniffed: option("--protocol", in: args).flatMap(Rule.Sniffed.init(rawValue:)))
            let answer = RuleTester.route(query, plan: model.connection.routingPlan, custom: custom, geo: model.ruleCatalog.lists)
            let result = answer.map { "index=\($0.index) route=\($0.outbound ?? $0.balancer ?? "default") matched=\($0.matched ?? "conditions")" } ?? "default"
            return response(command: "rules test", revision: revision(), data: result)
        case "import":
            let data = try inputData(file: option("--file", in: args), stdin: stdin)
            let imported = try RuleImport(data: data)
            let preview = "Format: \(imported.format.rawValue)\nRules: \(imported.rules.count)\nSkipped: \(imported.skipped.count)"
            guard args.contains("--apply") else { return response(command: "rules import", revision: revision(), data: preview, warnings: imported.skipped) }
            return try mutate(command: "rules import", profile: profile, args: args, proposed: current + model.resolvingVia(imported.rules), model: model, detail: preview)
        case "apply":
            return try mutate(command: "rules apply", profile: profile, args: args,
                              proposed: readRules(file: option("--file", in: args), stdin: stdin), model: model)
        case "create":
            var rule = try ruleFromInput(args, stdin: stdin) ?? Rule(name: option("--name", in: args) ?? "", action: try action(option("--action", in: args)))
            rule.items += options("--item", in: args).compactMap { Rule.Item.parse($0).items.first }
            return try mutate(command: "rules create", profile: profile, args: args, proposed: current + [rule], model: model, detail: rule.id.uuidString)
        case "update", "delete", "enable", "disable", "move":
            let token = positionals(args).dropFirst().first
            let target = try selectedRule(token, in: current)
            var proposed = current
            let index = proposed.firstIndex { $0.id == target.id }!
            if verb == "delete" { proposed.remove(at: index) }
            else if verb == "enable" { proposed[index].enabled = true }
            else if verb == "disable" { proposed[index].enabled = false }
            else if verb == "move" {
                guard let position = option("--to", in: args).flatMap(Int.init), (1...proposed.count).contains(position) else { throw usage("--to must be a 1-based rule position.") }
                let moved = proposed.remove(at: index); proposed.insert(moved, at: position - 1)
            } else {
                if var replacement = try ruleFromInput(args, stdin: stdin) { replacement.id = target.id; proposed[index] = replacement }
                if let name = option("--name", in: args) { proposed[index].name = name }
                if let value = option("--action", in: args) { proposed[index].action = try action(value) }
            }
            return try mutate(command: "rules \(verb)", profile: profile, args: args, proposed: proposed, model: model)
        case "items":
            let words = positionals(args)
            guard words.count > 2 else { throw usage("Use rules items add|remove RULE --item VALUE.") }
            let op = words[1], target = try selectedRule(words[2], in: current)
            let values = options("--item", in: args)
            var proposed = current; let i = proposed.firstIndex { $0.id == target.id }!
            if op == "add" { proposed[i].items += values.flatMap { Rule.Item.parse($0).items }.filter { !proposed[i].items.contains($0) } }
            else if op == "remove" {
                let items = values.flatMap { Rule.Item.parse($0).items }
                proposed[i].items.removeAll { items.contains($0) || values.contains($0.text) }
            }
            else { throw usage("Use rules items add or remove.") }
            return try mutate(command: "rules items \(op)", profile: profile, args: args, proposed: proposed, model: model)
        default:
            throw usage("Unsupported rules command: \(verb).")
        }
    }

    private func profiles(_ args: [String], model: AppModel) throws -> String {
        guard let verb = args.first else { throw usage("Missing profiles command.") }
        var profiles = syncedProfiles()
        if verb == "list" { return response(command: "rules profiles list", revision: revision(), data: profiles.map { "\($0.id)\t\($0.name)\($0.id == Prefs.activeRuleProfile ? "\tactive" : "")" }.joined(separator: "\n")) }
        try requireRevision(args)
        if model.rules.hasChanges { throw conflict("The Rules window has an unapplied draft.") }
        switch verb {
        case "create":
            let name = try nonempty(option("--name", in: args)); profiles.append(.init(name: name, rules: []))
        case "rename":
            let id = try selectedProfile(positionals(args).dropFirst().first).id, name = try nonempty(option("--name", in: args)); profiles[profiles.firstIndex { $0.id == id }!].name = name
        case "delete":
            let id = try selectedProfile(positionals(args).dropFirst().first).id
            guard profiles.count > 1 else { throw CLIError("invalid_data", "The last profile cannot be deleted.", EX_DATAERR) }
            profiles.removeAll { $0.id == id }
            if Prefs.activeRuleProfile == id { Prefs.activeRuleProfile = profiles[0].id; Prefs.rules = profiles[0].rules; model.rules.reload(); model.rules.onApplied() }
        case "switch":
            let id = try selectedProfile(positionals(args).dropFirst().first).id
            if !args.contains("--dry-run") { Prefs.ruleProfiles = profiles; Prefs.switchRuleProfile(to: id); model.rules.reload(); model.rules.onApplied() }
            return response(command: "rules profiles switch", revision: args.contains("--dry-run") ? revision() : revision(), data: args.contains("--dry-run") ? "Would switch profile" : "Switched profile")
        default: throw usage("Unsupported profiles command: \(verb).")
        }
        if !args.contains("--dry-run") { Prefs.ruleProfiles = profiles }
        return response(command: "rules profiles \(verb)", revision: revision(), data: args.contains("--dry-run") ? "No changes saved" : "Done")
    }

    private func builtIns(_ args: [String], model: AppModel) throws -> String {
        let block = UserDefaults.standard.bool(forKey: "blockQUIC")
        let fallback = UserDefaults.standard.string(forKey: "unmatchedRoute") ?? "mode"
        guard args.first == "set" else { return response(command: "rules built-ins show", revision: revision(), data: "Local network\tdirect\tlocked\nBlock QUIC\t\(block ? "on" : "off")\nApps using proxy port\tlocked\nMode rules\tlocked\nEverything else\t\(fallback)") }
        try requireRevision(args)
        if model.rules.hasChanges { throw conflict("The Rules window has an unapplied draft.") }
        let newBlock = option("--block-quic", in: args).map { $0 == "on" ? true : $0 == "off" ? false : nil } ?? nil
        let newFallback = option("--everything-else", in: args)
        if let newFallback, !["mode", "proxy", "direct", "block"].contains(newFallback) { throw CLIError("invalid_data", "Invalid Everything Else route.", EX_DATAERR) }
        if !args.contains("--dry-run") {
            if let newBlock { UserDefaults.standard.set(newBlock, forKey: "blockQUIC") }
            if let newFallback { UserDefaults.standard.set(newFallback, forKey: "unmatchedRoute") }
            if newBlock != nil || newFallback != nil { model.rules.onApplied() }
        }
        return response(command: "rules built-ins set", revision: revision(), data: args.contains("--dry-run") ? "No changes saved" : "Done")
    }

    private func mutate(command: String, profile: RuleProfileV2, args: [String], proposed: [Rule], model: AppModel, detail: String? = nil) throws -> String {
        try requireRevision(args)
        try validate(proposed, model: model)
        let active = profile.id == Prefs.activeRuleProfile
        if active, model.rules.hasChanges { throw conflict("The active profile has an unapplied Rules window draft.") }
        let summary = detail ?? diff(rules(for: profile), proposed)
        guard !args.contains("--dry-run") else { return response(command: command, revision: revision(), data: summary) }
        var profiles = syncedProfiles()
        profiles[profiles.firstIndex { $0.id == profile.id }!].rules = proposed
        Prefs.ruleProfiles = profiles
        if active { Prefs.rules = proposed; model.rules.reload(); model.rules.onApplied() }
        return response(command: command, revision: revision(), data: summary)
    }

    private func validate(_ rules: [Rule], model: AppModel) throws {
        let targets = Set(((try? model.context.fetch(FetchDescriptor<Profile>())) ?? []).map(\.id))
        let groups = Set(((try? model.context.fetch(FetchDescriptor<ServerGroup>())) ?? []).map(\.id))
        for rule in rules {
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("Rule names cannot be empty.") }
            guard !rule.items.isEmpty || !rule.only.isEmpty else { throw invalid("“\(rule.name)” can never match.") }
            guard rule.only.ports.isEmpty || Rule.OnlyWhen.validPorts(rule.only.ports) else { throw invalid("“\(rule.name)” has invalid ports.") }
            for item in rule.items {
                guard item.kind != .invalid else { throw invalid("“\(rule.name)” has an invalid item: \(item.text).") }
                if item.kind == .regex, (try? Regex(item.text)) == nil { throw invalid("“\(rule.name)” has an invalid regular expression.") }
                if item.kind == .country, !GeoTags.isCountry(item.text) { throw invalid("“\(rule.name)” has an invalid country.") }
                if item.kind == .service, !model.ruleCatalog.lists.isEmpty, !model.ruleCatalog.lists.containsList(item.text) {
                    throw invalid("“\(rule.name)” uses an unavailable geo list: \(item.text).")
                }
            }
            if case .via(let via) = rule.action {
                let exists = switch via.target { case .server(let id): targets.contains(id); case .group(let id): groups.contains(id) }
                guard exists else { throw invalid("“\(rule.name)” has a missing Via target.") }
            }
        }
    }

    private func syncedProfiles() -> [RuleProfileV2] {
        var profiles = Prefs.ruleProfiles
        if let i = profiles.firstIndex(where: { $0.id == Prefs.activeRuleProfile }) { profiles[i].rules = Prefs.rules }
        return profiles
    }
    private func rules(for profile: RuleProfileV2) -> [Rule] { profile.id == Prefs.activeRuleProfile ? Prefs.rules : profile.rules }
    private func selectedProfile(_ token: String?) throws -> RuleProfileV2 {
        let profiles = syncedProfiles()
        guard let token else { return profiles.first { $0.id == Prefs.activeRuleProfile }! }
        if let id = UUID(uuidString: token), let hit = profiles.first(where: { $0.id == id }) { return hit }
        let hits = profiles.filter { $0.name == token }
        guard hits.count == 1 else { throw CLIError(hits.isEmpty ? "not_found" : "ambiguous_name", hits.isEmpty ? "Profile not found." : "Profile name is ambiguous.", EX_DATAERR) }
        return hits[0]
    }
    private func selectedRule(_ token: String?, in rules: [Rule]) throws -> Rule {
        guard let token else { throw usage("A rule UUID or exact name is required.") }
        if let id = UUID(uuidString: token), let hit = rules.first(where: { $0.id == id }) { return hit }
        let hits = rules.filter { $0.name == token }
        guard hits.count == 1 else { throw CLIError(hits.isEmpty ? "not_found" : "ambiguous_name", hits.isEmpty ? "Rule not found." : "Rule name is ambiguous.", EX_DATAERR) }
        return hits[0]
    }
    private func requireRevision(_ args: [String]) throws {
        guard let supplied = option("--revision", in: args) else { throw usage("Every write requires --revision.") }
        guard supplied == revision() else { throw conflict("The rules changed; fetch the current revision and retry.") }
    }
    private func revision() -> String {
        let profiles = syncedProfiles()
        let state = RevisionState(profiles: profiles, active: Prefs.activeRuleProfile, blockQUIC: UserDefaults.standard.bool(forKey: "blockQUIC"), everythingElse: UserDefaults.standard.string(forKey: "unmatchedRoute") ?? "mode")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(state)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    private func readRules(file: String?, stdin: String?) throws -> [Rule] {
        let text = String(decoding: try inputData(file: file, stdin: stdin), as: UTF8.self)
        guard let rules = Rule.decode(text) else { throw invalid("Expected canonical V2Mac version-2 rule JSON.") }
        return rules
    }
    private func ruleFromInput(_ args: [String], stdin: String?) throws -> Rule? {
        guard option("--file", in: args) != nil || args.contains("-") else { return nil }
        let rules = try readRules(file: option("--file", in: args), stdin: stdin)
        guard rules.count == 1 else { throw invalid("Create/update input must contain exactly one rule.") }
        return rules[0]
    }
    private func inputData(file: String?, stdin: String?) throws -> Data {
        if let file { return try Data(contentsOf: URL(fileURLWithPath: file)) }
        if let stdin { return Data(stdin.utf8) }
        throw usage("Use --file PATH or - for stdin.")
    }
    private func action(_ value: String?) throws -> Rule.Action {
        switch value { case "proxy": return .proxy; case "direct": return .direct; case "block": return .block; default: throw invalid("--action must be proxy, direct, or block.") }
    }
    private func nonempty(_ value: String?) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("A non-empty --name is required.") }; return value
    }
    private func render(_ rules: [Rule]) -> String { rules.enumerated().map { "\($0.offset + 1)\t\($0.element.id)\t\($0.element.enabled ? "on" : "off")\t\($0.element.name)" }.joined(separator: "\n") }
    private func diff(_ old: [Rule], _ new: [Rule]) -> String { "Rules: \(old.count) → \(new.count)" }
    private func tidyID(_ suggestion: TidySuggestion) -> String {
        let digest = SHA256.hash(data: Data(String(describing: suggestion.kind).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "tidy-" + digest
    }
    private func json<T: Encodable>(_ value: T) -> String { String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self) }
    private func option(_ name: String, in args: [String]) -> String? { args.indices.first { args[$0] == name && args.indices.contains($0 + 1) }.map { args[$0 + 1] } }
    private func options(_ name: String, in args: [String]) -> [String] { args.indices.filter { args[$0] == name && args.indices.contains($0 + 1) }.map { args[$0 + 1] } }
    private func positionals(_ args: [String]) -> [String] {
        let flags: Set<String> = ["--json", "--dry-run", "--apply"]
        var out: [String] = [], skip = false
        for value in args {
            if skip { skip = false; continue }
            if value.hasPrefix("--") { if !flags.contains(value) { skip = true }; continue }
            if value != "-" { out.append(value) }
        }
        return out
    }

    private func response(command: String, revision: String? = nil, data: String? = nil, warnings: [String] = [], error: CLIWireError? = nil) -> String {
        let value = CLIWireResponse(ok: error == nil, command: command, revision: revision, data: data, warnings: warnings, error: error, appHash: appHash)
        return String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }
    private func usage(_ text: String) -> CLIError { CLIError("usage", text, EX_USAGE) }
    private func invalid(_ text: String) -> CLIError { CLIError("invalid_data", text, EX_DATAERR) }
    private func conflict(_ text: String) -> CLIError { CLIError("conflict", text, EX_TEMPFAIL) }
    private func internalError(_ text: String) -> CLIWireError { .init(id: "internal", message: text, exitCode: EX_SOFTWARE) }

    nonisolated private static func validClient(pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let actual = URL(fileURLWithPath: String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)).resolvingSymlinksInPath().standardizedFileURL
        let expected = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/v2mac").resolvingSymlinksInPath().standardizedFileURL
        guard actual == expected, hash(actual) == hash(expected) else { return false }
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(actual as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("identifier \"\(V2MacCLIIdentity.cliIdentifier)\"" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code!, .init(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return false }
        return true
    }
    nonisolated private static func hash(_ url: URL) -> String? { try? SHA256.hash(data: Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined() }
}

private struct RevisionState: Codable { var profiles: [RuleProfileV2]; var active: UUID?; var blockQUIC: Bool; var everythingElse: String }
private struct CLIError: Error { var id: String; var message: String; var code: Int32; init(_ id: String, _ message: String, _ code: Int32) { self.id = id; self.message = message; self.code = code } }

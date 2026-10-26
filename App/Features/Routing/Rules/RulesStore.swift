import SwiftUI
import V2MacCore

/// Spec 8.6: the Rules window's state. Edits change a draft; Apply saves it and restarts the core once.
/// One per app, so a draft survives the window closing and the Connections window and the menu bar can
/// add to the same list.
@MainActor @Observable
final class RulesStore {
    enum Selection: Hashable {
        case rule(UUID)
        case builtIn(BuiltIn)
        case discovered
    }

    /// Rows the user cannot move or delete, in evaluation order around the user's rules.
    enum BuiltIn: String, Hashable, CaseIterable {
        case localNetwork, blockQUIC, proxyPort, mode, everythingElse
    }

    private(set) var saved: [Rule] = Prefs.rules
    private(set) var draft: [Rule] = Prefs.rules
    var selection: Set<Selection> = []
    /// Rule ids by when they last received an item from "Add to", newest first.
    private(set) var recentTargets: [UUID] = []
    @ObservationIgnored var onApplied: () -> Void = {}

    var hasChanges: Bool { draft != saved }

    /// Rules added, edited or moved, plus deleted ones.
    var changeCount: Int {
        let old = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let edited = draft.enumerated().filter { i, rule in old[rule.id] != rule || saved.firstIndex { $0.id == rule.id } != i }.count
        return edited + saved.filter { rule in !draft.contains { $0.id == rule.id } }.count
    }

    func isChanged(_ rule: Rule) -> Bool { !saved.contains(rule) }

    var selectedRule: Rule? {
        guard selection.count == 1, case .rule(let id)? = selection.first else { return nil }
        return draft.first { $0.id == id }
    }

    var selectedRuleIDs: [UUID] {
        draft.map(\.id).filter { selection.contains(.rule($0)) }
    }

    // MARK: Editing

    /// Every edit goes through here, so ⌘Z restores the list as it was before it.
    func change(_ undo: UndoManager?, _ edit: (inout [Rule]) -> Void) {
        let before = draft
        edit(&draft)
        guard draft != before else { return }
        undo?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.change(undo) { $0 = before } }
        }
    }

    func update(_ id: UUID, _ undo: UndoManager?, _ edit: (inout Rule) -> Void) {
        change(undo) { rules in
            if let i = rules.firstIndex(where: { $0.id == id }) { edit(&rules[i]) }
        }
    }

    func add(_ rule: Rule, after: UUID? = nil, _ undo: UndoManager?) {
        change(undo) { rules in
            let index = after.flatMap { id in rules.firstIndex { $0.id == id }.map { $0 + 1 } } ?? rules.count
            rules.insert(rule, at: index)
        }
        selection = [.rule(rule.id)]
    }

    /// Items added to an existing rule, skipping ones it already has.
    func add(_ items: [Rule.Item], to id: UUID, _ undo: UndoManager?) {
        update(id, undo) { rule in rule.items += items.filter { !rule.items.contains($0) } }
        recentTargets.removeAll { $0 == id }
        recentTargets.insert(id, at: 0)
    }

    func delete(_ ids: [UUID], _ undo: UndoManager?) {
        change(undo) { $0.removeAll { ids.contains($0.id) } }
        selection.subtract(ids.map(Selection.rule))
    }

    func duplicate(_ id: UUID, _ undo: UndoManager?) {
        guard var copy = draft.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name = String(localized: "\(copy.name) copy")
        add(copy, after: id, undo)
    }

    // MARK: Saving

    func apply() {
        Prefs.rules = draft
        saved = draft
        onApplied()
    }

    func revert() {
        draft = saved
    }

    /// The saved list again, after a profile switch or a restore.
    func reload() {
        saved = Prefs.rules
        draft = saved
        selection = selection.filter { if case .rule(let id) = $0 { saved.contains { $0.id == id } } else { true } }
    }

    // MARK: Profiles

    func switchProfile(to id: UUID) {
        guard !hasChanges, id != Prefs.activeRuleProfile else { return }
        Prefs.switchRuleProfile(to: id)
        reload()
        onApplied()
    }

    func addProfile(copying rules: [Rule]) {
        // A copy gets new ids, so the two profiles' rules never share one.
        let copied = rules.map { var r = $0; r.id = UUID(); return r }
        let profile = RuleProfileV2(name: String(localized: "Profile \(Prefs.ruleProfiles.count + 1)"), rules: copied)
        Prefs.ruleProfiles += [profile]
        switchProfile(to: profile.id)
    }

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var profiles = Prefs.ruleProfiles
        if let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].name = trimmed }
        Prefs.ruleProfiles = profiles
    }

    func deleteProfile(_ id: UUID) {
        var profiles = Prefs.ruleProfiles
        guard !hasChanges, profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: i)
        Prefs.ruleProfiles = profiles
        // The next one becomes active; its rules replace the deleted profile's.
        let next = profiles[min(i, profiles.count - 1)]
        Prefs.activeRuleProfile = next.id
        Prefs.rules = next.rules
        reload()
        onApplied()
    }
}

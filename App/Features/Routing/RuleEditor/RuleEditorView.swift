import SwiftUI
import V2MacCore

/// Spec 8.6: the rule editor window. Simple mode drags apps and sites into Proxy or Direct;
/// Advanced is the ordered list of Settings → Routing. The toolbar switches rule profiles.
struct RuleEditorView: View {
    static let windowID = "rule-editor"

    enum Mode: String, CaseIterable, Identifiable {
        case simple, advanced
        var id: Self { self }
        var title: LocalizedStringKey { self == .simple ? "Simple" : "Advanced" }
    }

    @AppStorage("ruleEditorMode") private var mode = Mode.simple

    var body: some View {
        Group {
            switch mode {
            case .simple: SimpleRuleEditor()
            case .advanced:
                Form { CustomRulesSection() }
                    .formStyle(.grouped)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) { RuleProfileMenu() }
        }
    }
}

/// Picks, adds, renames and deletes rule profiles. Switching restarts a running core.
private struct RuleProfileMenu: View {
    @Environment(AppModel.self) private var model
    // Read so the menu redraws when either changes.
    @AppStorage("ruleProfiles") private var storedProfiles = "[]"
    @AppStorage("activeRuleProfile") private var storedActive = ""
    @State private var renaming: RuleProfile?
    @State private var name = ""

    var body: some View {
        let _ = (storedProfiles, storedActive)
        let profiles = Prefs.ruleProfiles
        let active = Prefs.activeRuleProfile
        Menu {
            Picker("Profile", selection: Binding { active } set: { id in if let id { choose(id) } }) {
                ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New Profile") { add(rules: []) }
            Button("Duplicate Profile") { add(rules: Prefs.customRuleList) }
            Button("Rename Profile…") {
                renaming = profiles.first { $0.id == active }
                name = renaming?.name ?? ""
            }
            Button("Delete Profile", role: .destructive) { delete(active) }
                .disabled(profiles.count < 2)
        } label: {
            Label(profiles.first { $0.id == active }?.name ?? "", systemImage: "square.stack.3d.up")
                .labelStyle(.titleAndIcon)
        }
        .help("Rule profile")
        .alert("Rename Profile", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename() }
        }
    }

    private func choose(_ id: UUID) {
        guard id != Prefs.activeRuleProfile else { return }
        Prefs.switchRuleProfile(to: id)
        model.connection.reconnectIfRunning()
    }

    private func add(rules: [CustomRule]) {
        let profile = RuleProfile(name: String(localized: "Profile \(Prefs.ruleProfiles.count + 1)"), rules: rules)
        Prefs.ruleProfiles += [profile]
        choose(profile.id)
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = renaming?.id, !trimmed.isEmpty else { return }
        var profiles = Prefs.ruleProfiles
        if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index].name = trimmed }
        Prefs.ruleProfiles = profiles
    }

    private func delete(_ id: UUID?) {
        var profiles = Prefs.ruleProfiles
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        Prefs.ruleProfiles = profiles
        // The next one becomes active; its rules replace the deleted profile's.
        let next = profiles[min(index, profiles.count - 1)]
        Prefs.activeRuleProfile = next.id
        Prefs.customRuleList = next.rules
        model.connection.reconnectIfRunning()
    }
}

import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import V2MacCore

/// Spec 8.6 and 12.x: the Rules window. The sidebar lists every rule in the order the core checks them:
/// the built-ins, the user's rules (drag to reorder), the mode's own rules and "Everything else".
/// The detail edits the selected rule. Edits form a draft that Apply saves with one core restart.
struct RulesWindow: View {
    static let windowID = "rules"

    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var importing = false
    @State private var imported: RuleImport?
    @State private var importError: String?
    @State private var exporting: RulesDocument?
    @State private var tidying: [TidySuggestion]?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", proxy = "Proxy", via = "Via", direct = "Direct", block = "Block"
        var id: Self { self }
        var title: LocalizedStringKey { LocalizedStringKey(rawValue) }

        func admits(_ action: Rule.Action) -> Bool {
            switch (self, action) {
            case (.all, _), (.proxy, .proxy), (.via, .via), (.direct, .direct), (.block, .block): true
            default: false
            }
        }
    }

    var body: some View {
        let store = model.rules
        NavigationSplitView {
            RulesSidebar(search: $search, filter: $filter)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 440)
        } detail: {
            RulesDetail(search: search)
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search rules, apps, hosts")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.hasChanges { ApplyBar() }
        }
        .toolbar { toolbar }
        .frame(minWidth: 860, minHeight: 520)
        .background(WindowCloseGuard { shouldClose() })
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { imported = try RuleImport(data: Data(contentsOf: url)) }
            catch { importError = String(localized: "This file has no rules V2Mac can read.") }
        }
        .sheet(item: $imported) { profile in
            RuleImportSheet(profile: profile) { rules in
                store.change(undo) { $0 += model.resolvingVia(rules) }
                if profile.blockQUIC { UserDefaults.standard.set(true, forKey: "blockQUIC"); model.connection.reconnectIfRunning() }
            }
        }
        .sheet(item: Binding { tidying.map(TidyList.init) } set: { tidying = $0?.suggestions }) { list in
            TidyUpSheet(suggestions: list.suggestions) { chosen in
                store.change(undo) { $0 = TidyUp.apply(chosen, to: $0) }
            }
        }
        .fileExporter(isPresented: Binding { exporting != nil } set: { if !$0 { exporting = nil } }, document: exporting,
                      contentType: .json, defaultFilename: String(localized: "V2Mac Rules")) { _ in }
        .alert("Import Failed", isPresented: Binding { importError != nil } set: { if !$0 { importError = nil } }) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .task { await model.ruleCatalog.load() }
        .onAppear { model.connection.watcher.watch() }
        .onDisappear { model.connection.watcher.unwatch() }
    }

    static let importTypes: [UTType] = [.json, .xml, .yaml, .plainText, .data].compactMap { $0 } + [UTType(filenameExtension: "ppx"), UTType(filenameExtension: "conf")].compactMap { $0 }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let store = model.rules
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Empty Rule") { store.add(Rule(name: String(localized: "New rule"), action: .proxy), after: store.selectedRule?.id, undo) }
                Divider()
                ForEach(RuleTemplate.all) { template in
                    Button(template.name) {
                        let rule = template.rule(available: Set(model.ruleCatalog.geo.lists), installed: model.ruleCatalog.apps,
                                                 regions: model.regionPacks.usableRoutes)
                        store.add(rule, after: store.selectedRule?.id, undo)
                    }
                    .disabled(template.id == .region && model.regionPacks.usableRoutes.isEmpty)
                }
            } label: {
                Label("New Rule", systemImage: "plus")
            } primaryAction: {
                store.add(Rule(name: String(localized: "New rule"), action: .proxy), after: store.selectedRule?.id, undo)
            }
            .help("Add a rule below the selected one, or start from a template")
        }
        ToolbarItem(placement: .primaryAction) { RuleProfileMenu() }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Import Rules…") { importing = true }
                Button("Export All Rules…") { exporting = RulesDocument(rules: store.draft) }
                Button("Export Selected Rules…") { exporting = RulesDocument(rules: store.draft.filter { store.selectedRuleIDs.contains($0.id) }) }
                    .disabled(store.selectedRuleIDs.isEmpty)
                Divider()
                Button("Tidy Up…") { tidying = TidyUp.suggestions(for: store.draft, apps: model.ruleCatalog.apps) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    /// Spec 8.6: closing with changes not applied asks first.
    private func shouldClose() -> Bool {
        let store = model.rules
        guard store.hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Apply your rule changes?")
        alert.informativeText = String(localized: "\(store.changeCount) changes are not applied yet.")
        alert.addButton(withTitle: String(localized: "Apply"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Discard"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: store.apply(); return true
        case .alertThirdButtonReturn: store.revert(); return true
        default: return false
        }
    }
}

private struct TidyList: Identifiable {
    let suggestions: [TidySuggestion]
    var id: Int { suggestions.hashValue }
}

extension RuleImport: Identifiable {
    public var id: Int { rules.hashValue ^ skipped.hashValue }
}

/// "N changes · Revert · Apply (⌘S)".
private struct ApplyBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
            Text("\(model.rules.changeCount) changes").foregroundStyle(.secondary)
            Spacer()
            Button("Revert") { model.rules.revert() }
            Button("Apply") { model.rules.apply() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// The rules as V2Mac's own JSON, for export.
struct RulesDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let rules: [Rule]

    init(rules: [Rule]) { self.rules = rules }
    init(configuration: ReadConfiguration) throws { rules = Rule.decode(String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)) ?? [] }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(Rule.encode(rules).utf8))
    }
}

/// Asks before the window closes. It sits between the window and SwiftUI's own delegate, passing
/// everything else on.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: @MainActor () -> Bool

    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ view: GuardView, context: Context) { view.shouldClose = shouldClose }

    final class GuardView: NSView, NSWindowDelegate {
        var shouldClose: @MainActor () -> Bool = { true }
        private weak var original: NSWindowDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== self else { return }
            original = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldClose() && (original?.windowShouldClose?(sender) ?? true)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}

import AppKit
import SwiftUI

/// Spec 13: the app's own language, kept as this app's `AppleLanguages`, as the per-app
/// language in System Settings does. It takes effect when V2Mac opens again.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "", english = "en", persian = "fa", chinese = "zh-Hans", russian = "ru"

    var id: String { rawValue }

    /// Each language in its own name, so it can be found whatever the current one is.
    var title: String {
        switch self {
        case .system: String(localized: "Same as the system")
        case .english: "English"
        case .persian: "فارسی"
        case .chinese: "简体中文"
        case .russian: "Русский"
        }
    }

    /// Read from this app's own preferences only; the system's list is not a choice made here.
    static var chosen: AppLanguage {
        let languages = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        return languages?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// macOS mirrors an app only for its own right-to-left system languages, and Persian is not
    /// one of them, so the app asks AppKit for a right-to-left layout itself when its language is.
    /// Registered, not saved: it follows whichever language the app opens in.
    static func applyLayoutDirection() {
        guard let code = Bundle.main.preferredLocalizations.first,
              Locale.Language(identifier: code).characterDirection == .rightToLeft else { return }
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleTextDirection"] = true
        arguments["NSForceRightToLeftWritingDirection"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Quits through the usual path (the core stops first) and opens V2Mac again once it is gone.
    @MainActor static func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                            Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }
}

struct LanguagePicker: View {
    @State private var language = AppLanguage.chosen
    private let atLaunch = AppLanguage.chosen

    var body: some View {
        Picker("Language", selection: $language) {
            ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
        }
        .onChange(of: language) { AppLanguage.choose(language) }
        if language != atLaunch {
            HStack {
                Text("V2Mac changes its language when it opens again.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restart Now") { AppLanguage.relaunch() }
                    .controlSize(.small)
            }
        }
    }
}

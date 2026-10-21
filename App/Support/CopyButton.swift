import SwiftUI

/// A button that copies text and shows a checkmark for a moment, so the click visibly did something.
struct CopyButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let text: () -> String
    /// Asks for Touch ID first when that setting is on (`OwnerCheck`), for secrets.
    var ownerReason: String?

    @State private var copied = false

    init(_ title: LocalizedStringKey, systemImage: String = "doc.on.doc", ownerReason: String? = nil, text: @escaping () -> String) {
        self.title = title
        self.systemImage = systemImage
        self.ownerReason = ownerReason
        self.text = text
    }

    var body: some View {
        Button(title, systemImage: copied ? "checkmark" : systemImage, action: copy)
            .contentTransition(.symbolEffect(.replace))
    }

    private func copy() {
        Task {
            if let ownerReason, !(await OwnerCheck.confirm(ownerReason)) { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

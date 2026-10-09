import SwiftUI

/// A button that copies text and shows a checkmark for a moment, so the click visibly did something.
struct CopyButton: View {
    let title: String
    let systemImage: String
    let text: () -> String

    @State private var copied = false

    init(_ title: String, systemImage: String = "doc.on.doc", text: @escaping () -> String) {
        self.title = title
        self.systemImage = systemImage
        self.text = text
    }

    var body: some View {
        Button(title, systemImage: copied ? "checkmark" : systemImage, action: copy)
            .contentTransition(.symbolEffect(.replace))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

import SwiftUI

/// The rule editor's button at the foot of the sidebar: an icon on glass whose name slides out
/// beside it, with a soft glow, while the pointer is over it.
struct RuleEditorButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button { model.openRuleEditor(openWindow) } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title3.weight(.semibold))
                    .symbolEffect(.bounce, value: isHovering)
                if isHovering {
                    Text("Rule Editor")
                        .fontWeight(.medium)
                        .fixedSize()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(isHovering ? Color.accentColor.opacity(0.25) : nil).interactive(), in: .capsule)
        .shadow(color: Color.accentColor.opacity(isHovering ? 0.55 : 0), radius: isHovering ? 12 : 0)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.25)) { isHovering = hovering }
        }
        .accessibilityLabel("Rule Editor")
        .help("Rule Editor")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

import SwiftUI

/// The tools at the foot of the sidebar: the connections window, the rule editor and the sandbox.
struct SidebarTools: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                SidebarGlassButton(title: "Connections", systemImage: "point.3.connected.trianglepath.dotted") {
                    model.openConnections(openWindow)
                }
                SidebarGlassButton(title: "Rule Editor", systemImage: "arrow.triangle.branch") { model.openRuleEditor(openWindow) }
                if model.sandbox.pin != nil {
                    SidebarGlassButton(title: "Sandbox", systemImage: "shield.lefthalf.filled") { model.sandbox.open() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

/// An icon on glass whose name slides out beside it, with a soft glow, while the pointer is over it.
struct SidebarGlassButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .symbolEffect(.bounce, value: isHovering)
                if isHovering {
                    Text(title)
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
        .accessibilityLabel(title)
        .help(title)
    }
}

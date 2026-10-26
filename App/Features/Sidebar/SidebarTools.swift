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
                SidebarGlassButton(title: "Rules", systemImage: "arrow.triangle.branch") { model.openRules(openWindow) }
                if model.sandbox.pin != nil {
                    HStack(spacing: 8) {
                        SidebarGlassButton(title: "Sandbox (beta)", systemImage: "shield.lefthalf.filled", loading: model.sandbox.isOpening,
                                           badge: model.sandbox.phase == .installed ? nil : "arrow.down.circle.fill") { model.sandbox.open() }
                        // The same update button as V2Mac's own, for the sandbox's update.
                        if model.sandbox.updateAvailable {
                            UpdateButton(title: "Sandbox Update Available", opensTrailing: true, tab: .sandbox)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

/// An icon on glass whose name slides out beside it, with a soft glow, while the pointer is over it.
/// While `loading`, a spinner and "Loading…" with light sweeping across the glass; `badge` is a small
/// symbol beside the icon (the sandbox's "not installed").
struct SidebarGlassButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var loading = false
    var badge: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Loading…").fontWeight(.medium).fixedSize()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .symbolEffect(.bounce, value: isHovering)
                    if let badge {
                        Image(systemName: badge).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                            .padding(.leading, -4).accessibilityHidden(true)
                    }
                }
                if isHovering && !loading {
                    Text(title)
                        .fontWeight(.medium)
                        .fixedSize()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .overlay { if loading && !reduceMotion { GlassSweep() } }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: loading)
        .glassEffect(.regular.tint(isHovering ? Color.accentColor.opacity(0.25) : nil).interactive(), in: .capsule)
        .shadow(color: Color.accentColor.opacity(isHovering ? 0.55 : 0), radius: isHovering ? 12 : 0)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.25)) { isHovering = hovering }
        }
        .accessibilityLabel(title)
        .help(title)
    }
}

/// A soft band of light that keeps crossing the glass from left to right.
private struct GlassSweep: View {
    @State private var across = false

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.6)
                .offset(x: across ? proxy.size.width : -proxy.size.width * 0.6)
        }
        .clipShape(.capsule)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { across = true } }
    }
}

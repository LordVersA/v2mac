import SwiftUI

/// A segmented choice on Liquid Glass: the chosen segment's tinted pill slides to it.
struct GlassSegments<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: LocalizedStringKey
        var systemImage: String? = nil
    }

    @Binding var selection: Value
    let items: [Item]
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    let isOn = item.value == selection
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.25)) { selection = item.value }
                    } label: {
                        HStack(spacing: 5) {
                            if let symbol = item.systemImage { Image(systemName: symbol) }
                            Text(item.title)
                        }
                        .font(.callout.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(.capsule)
                        // The chosen segment is a drop of glass that flows to the next one.
                        .glassEffect(isOn ? .regular.tint(Color.accentColor.opacity(0.35)).interactive() : .identity, in: .capsule)
                        .glassEffectID(isOn ? "selection" : "segment-\(index)", in: namespace)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

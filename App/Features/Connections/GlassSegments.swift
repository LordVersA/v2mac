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
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let isOn = item.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)) { selection = item.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = item.systemImage { Image(systemName: symbol) }
                        Text(item.title)
                    }
                    .font(.callout.weight(isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background {
                        if isOn {
                            Capsule().fill(Color.accentColor.opacity(0.22))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

import SwiftUI

/// The colour a subscription is marked with in the sidebar, the table and the menu bar panel.
/// The system's own colours, so they follow light and dark mode and increased contrast.
enum GroupColor: String, CaseIterable, Identifiable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .gray: .gray
        }
    }

    var title: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .mint: String(localized: "Mint")
        case .teal: String(localized: "Teal")
        case .gray: String(localized: "Gray")
        }
    }

    /// The colour a subscription gets until one is chosen: they differ from one to the next.
    static func automatic(_ index: Int) -> GroupColor {
        // Not in the picker's rainbow order, where neighbours such as blue and indigo look alike.
        let choices: [GroupColor] = [.blue, .orange, .purple, .green, .pink, .teal, .red, .yellow, .indigo, .mint]
        return choices[((index % choices.count) + choices.count) % choices.count]
    }
}

extension ServerGroup {
    /// The chosen colour; without one, blue for Custom Configs and one by position for a subscription.
    var tint: GroupColor {
        if let chosen = colorName.flatMap(GroupColor.init(rawValue:)) { return chosen }
        return isManual ? .blue : .automatic(sortIndex)
    }
}

/// A subscription's name on its colour, as a small capsule.
struct GroupTag: View {
    let name: String
    let color: GroupColor
    /// Increased on a selected table row, where the colour would vanish into the highlight.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onHighlight = prominence == .increased
        Text(name)
            .font(.caption)
            .foregroundStyle(onHighlight ? AnyShapeStyle(.white) : AnyShapeStyle(color.color))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(onHighlight ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(color.color.opacity(0.16)), in: .capsule)
            .accessibilityLabel("Subscription \(name)")
    }
}

/// A subscription's colour as a dot, where a capsule would be too heavy.
struct GroupDot: View {
    let color: GroupColor

    var body: some View {
        Circle().fill(color.color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// A row of swatches to pick a subscription's colour from, as Finder's tag colours.
struct GroupColorPicker: View {
    @Binding var selection: GroupColor

    var body: some View {
        HStack(spacing: 7) {
            ForEach(GroupColor.allCases) { choice in
                Button {
                    selection = choice
                } label: {
                    Circle()
                        .fill(choice.color)
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay {
                            Circle().strokeBorder(choice.color, lineWidth: 2).opacity(choice == selection ? 1 : 0)
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(choice.title)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(choice == selection ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

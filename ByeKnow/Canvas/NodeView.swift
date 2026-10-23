import SwiftUI

struct NodeView: View {
    @Bindable var node: Node
    var selected: Bool
    var isOpen: Bool
    var editing: Bool
    var onEndEditing: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        let size = node.size
        content
            .frame(width: size.width, height: size.height)
            .background { background(size) }
            .overlay { ring }
    }

    // MARK: Content

    private var ink: Color {
        if node.isRoot && node.inkIndex == 0 { return .white }
        return Palette.swatch(node.inkIndex).ink
    }

    private var content: some View {
        VStack(spacing: 5) {
            if let theme = node.theme, !node.isRoot {
                Text(theme.name.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.swatch(theme.colorIndex).ink)
                    .lineLimit(1)
            }
            if editing {
                TextField(tr("Название"), text: $node.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .task {
                        try? await Task.sleep(for: .milliseconds(80))
                        focused = true
                    }
                    .onSubmit(onEndEditing)
                    .onChange(of: node.title) { _, new in
                        if new.contains("\n") {
                            node.title = new.replacingOccurrences(of: "\n", with: "")
                            onEndEditing()
                        }
                    }
            } else {
                Text(node.isRoot ? node.title : node.displayTitle)
                    .opacity(node.hasTitle ? 1 : 0.4)
                    .lineLimit(node.shape == .card ? 2 : 4)
            }
        }
        .font(node.isRoot
              ? .system(size: 22, weight: .bold, design: .rounded)
              : .system(size: 15, weight: .medium))
        .foregroundStyle(ink)
        .multilineTextAlignment(.center)
        .padding(node.isRoot || node.shape == .circle ? 24 : 14)
    }

    // MARK: Background

    @ViewBuilder
    private func background(_ size: CGSize) -> some View {
        if node.isRoot {
            let base = node.fillIndex == 0 ? Color.gray : Palette.swatch(node.fillIndex).ink
            Circle()
                .fill(base)
                .overlay(
                    Circle().fill(RadialGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0)],
                        center: UnitPoint(x: 0.32, y: 0.26),
                        startRadius: 0,
                        endRadius: size.width * 0.62
                    ))
                )
                .shadow(color: base.opacity(0.35), radius: 22, y: 10)
        } else {
            let shape = node.shape.outline
            let sticker = node.shape == .sticker
            shape
                .fill(Palette.swatch(node.fillIndex).fill)
                .overlay(shape.stroke(Color.primary.opacity(0.09), lineWidth: 1))
                .shadow(color: .black.opacity(sticker ? 0.14 : 0.06), radius: sticker ? 8 : 4, y: sticker ? 4 : 2)
        }
    }

    // MARK: Selection ring

    @ViewBuilder
    private var ring: some View {
        let outline = node.isRoot ? AnyShape(Circle()) : node.shape.outline
        if selected {
            outline
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(-5)
        } else if isOpen {
            outline
                .stroke(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .padding(-5)
        }
    }
}

import SwiftUI

struct NodeView: View, Equatable {
    /// Изменения самой заметки (название, цвет…) SwiftUI и так отслеживает через модель;
    /// здесь сравниваем только то, что приходит снаружи.
    static func == (a: NodeView, b: NodeView) -> Bool {
        a.node === b.node && a.selected == b.selected && a.isOpen == b.isOpen && a.editing == b.editing
    }

    @Bindable var node: Node
    var selected: Bool
    var isOpen: Bool
    var editing: Bool
    var onEndEditing: () -> Void

    @FocusState private var focused: Bool

    private var cosmos: Bool { AppSettings.shared.isCosmos }
    private var terminal: Bool { AppSettings.shared.isTerminal }

    /// В «Терминале» у карточек почти прямые углы, круг остаётся кругом.
    private var outline: AnyShape {
        if node.isRoot || node.shape == .circle { return AnyShape(Circle()) }
        return terminal ? AnyShape(RoundedRectangle(cornerRadius: 3, style: .continuous)) : node.shape.outline
    }

    /// Цвет свечения заметки в «Космосе».
    private var glow: Color { node.glowColor }

    var body: some View {
        let size = node.size
        content
            .frame(width: size.width, height: size.height)
            .background { background(size) }
            .overlay { ring }
            .overlay(alignment: .topTrailing) { aiMark }
    }

    /// Значок ✦ у заметки, которую видят ИИ-ассистенты.
    @ViewBuilder
    private var aiMark: some View {
        if node.isForAI && !node.isRoot {
            Image(systemName: AIAccess.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(terminal ? Term.ink(7) : AIAccess.color)
                .padding(node.shape == .circle ? 22 : 8)
                .allowsHitTesting(false)
                .help(L("Видна ИИ"))
        }
    }

    // MARK: Content

    private var ink: Color {
        // У цветной заметки в «Терминале» текст того же цвета, что и рамка.
        if terminal {
            if node.isRoot { return Term.ink(node.inkIndex) } // сфера — зелёная, если цвет текста не задан
            return Term.ink(node.inkIndex == 0 ? node.fillIndex : node.inkIndex)
        }
        if node.isRoot && node.inkIndex == 0 { return .white }
        return Palette.swatch(node.inkIndex).ink
    }

    private var content: some View {
        VStack(spacing: 5) {
            if let theme = node.theme, !node.isRoot {
                Text(terminal ? "[\(theme.name.lowercased())]" : theme.name.uppercased())
                    .font(.system(size: terminal ? 10 : 9, weight: .bold, design: terminal ? .monospaced : .default))
                    .tracking(terminal ? 0 : 0.6)
                    .foregroundStyle(Palette.swatch(theme.colorIndex).ink)
                    .lineLimit(1)
            }
            if editing {
                TextField(L("Название"), text: $node.title, axis: .vertical)
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
              ? .system(size: terminal ? 20 : 22, weight: .bold, design: terminal ? .monospaced : .rounded)
              : .system(size: terminal ? 14 : 15, weight: .medium, design: terminal ? .monospaced : .default))
        .foregroundStyle(ink)
        // Свечение люминофора, как на старом мониторе (тень статичная — ничего не стоит).
        .shadow(color: terminal ? ink.opacity(0.55) : .clear, radius: terminal ? 4 : 0)
        .multilineTextAlignment(.center)
        .padding(node.isRoot || node.shape == .circle ? 24 : 14)
    }

    // MARK: Background

    @ViewBuilder
    private func background(_ size: CGSize) -> some View {
        if terminal {
            terminalBackground
        } else if cosmos {
            cosmicBackground(size)
        } else {
            classicBackground(size)
        }
    }

    /// «Терминал»: чёрное окно с тонкой рамкой; сфера — круг с двойной рамкой.
    @ViewBuilder
    private var terminalBackground: some View {
        // Сфера в «Терминале» всегда зелёная — как приглашение командной строки.
        let color = node.isRoot ? Term.green : Term.ink(node.fillIndex)
        if node.isRoot {
            Circle()
                .fill(Term.bg)
                .overlay(Circle().stroke(color, lineWidth: 1.5))
                .overlay(Circle().inset(by: 7).stroke(color.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 4])))
        } else if node.fillIndex == 0 {
            outline
                .fill(Term.panel.opacity(0.94))
                .overlay(outline.stroke(color.opacity(0.7), lineWidth: 1))
        } else {
            // Цветная заметка: подкрашенный фон и рамка потолще — видно сразу.
            outline
                .fill(Term.panel.opacity(0.94))
                .overlay(outline.fill(color.opacity(0.12)))
                .overlay(outline.stroke(color, lineWidth: 1.6))
        }
    }

    /// В «Космосе» сферу и свечение рисуют слои Core Animation под заметкой (CosmicOrb, CosmicFlows),
    /// здесь — только стекло.
    @ViewBuilder
    private func cosmicBackground(_ size: CGSize) -> some View {
        if node.isRoot {
            Color.clear
        } else {
            let shape = node.shape.outline
            shape
                .fill(Cosmos.glass.opacity(0.88))
                .overlay(shape.fill(LinearGradient(colors: [glow.opacity(0.26), glow.opacity(0.04)],
                                                   startPoint: .top, endPoint: .bottom)))
                .overlay(shape.stroke(LinearGradient(colors: [glow.opacity(0.95), glow.opacity(0.2)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1.2))
        }
    }

    @ViewBuilder
    private func classicBackground(_ size: CGSize) -> some View {
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
        if selected {
            outline
                .stroke(terminal ? Term.green : (cosmos ? Color.white.opacity(0.9) : Color.accentColor),
                        lineWidth: terminal ? 1 : (cosmos ? 1.5 : 2))
                .padding(-5)
                .shadow(color: cosmos ? glow : .clear, radius: 8)
        } else if isOpen {
            outline
                .stroke((terminal ? Term.green : Color.accentColor).opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .padding(-5)
        }
    }
}

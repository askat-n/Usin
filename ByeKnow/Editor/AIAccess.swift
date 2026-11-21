import SwiftUI

/// Отметка «Для ИИ»: такую заметку видят ИИ-ассистенты (через MCP), остальные — только для себя.
enum AIAccess {
    static let symbol = "sparkles"
    static var color: Color { Palette.swatch(7).ink }
}

/// Переключатель «Для ИИ» в шапке заметки — рядом с темой.
struct AIAccessChip: View {
    @Bindable var node: Node

    var body: some View {
        Button {
            withAnimation(.snappy) { node.isForAI.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: AIAccess.symbol).font(.system(size: 11, weight: .semibold))
                Text(tr("Для ИИ"))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(node.isForAI ? AIAccess.color : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(node.isForAI ? AIAccess.color.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(node.isForAI
              ? tr("ИИ-ассистенты видят эту заметку. Нажми, чтобы сделать её личной")
              : tr("Личная заметка. Нажми, чтобы открыть её ИИ-ассистентам"))
    }
}

/// Пункт контекстного меню заметки.
struct AIAccessMenuItem: View {
    @Bindable var node: Node

    var body: some View {
        Button {
            node.isForAI.toggle()
        } label: {
            Label(node.isForAI ? tr("Скрыть от ИИ") : tr("Открыть для ИИ"),
                  systemImage: node.isForAI ? "sparkles.slash" : AIAccess.symbol)
        }
    }
}

import SwiftUI

/// Быстрая заметка из чёлки и строки меню: написал, нажал Enter — заметка уже в Usin, окно не открывается.
@MainActor
enum QuickNote {
    /// Первая строка — название (если не слишком длинная), остальное — текст заметки.
    @discardableResult
    static func save(_ text: String) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var lines = trimmed.components(separatedBy: .newlines)
        let first = lines[0].trimmingCharacters(in: .whitespaces)
        let title: String
        if first.count <= 60 {
            title = first
            lines.removeFirst()
        } else {
            title = ToolNote.title(from: first, fallback: L("Быстрая заметка"))
        }
        return ToolsHost.writeNote(ToolNote(title: title, lines: lines), .replace)
    }
}

/// Страница чёлки «Быстрая заметка».
struct NotchQuickNotePage: View {
    let takeKeyboard: () -> Void
    let close: () -> Void
    @State private var text = ""
    @State private var saved: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Быстрая заметка…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.11)))
                .onSubmit(save)
                .onExitCommand {
                    if text.isEmpty { close() } else { text = "" }
                }

            if let saved {
                HStack(spacing: 8) {
                    Label("Сохранено в Usin", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Открыть") {
                        close()
                        ToolsHost.openNote(saved)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                    .underline()
                }
                .font(.system(size: 11, weight: .medium))
            } else {
                Text("Enter — сохранить в Usin, ⌥Enter — новая строка. Первая строка станет названием.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .onAppear {
            // Кнопка страницы уже нажата: сразу можно печатать, как в Spotlight.
            takeKeyboard()
            DispatchQueue.main.async { focused = true }
        }
    }

    private func save() {
        guard let id = QuickNote.save(text) else { return }
        text = ""
        withAnimation(Motion.hover) { saved = id }
    }
}

/// Строка «Быстрая заметка…» в панели строки меню.
struct MenuBarQuickNote: View {
    @State private var text = ""
    @State private var savedAt: Date?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: savedAt == nil ? "square.and.pencil" : "checkmark.circle.fill")
                .foregroundStyle(savedAt == nil ? Color.secondary : .green)
                .contentTransition(.symbolEffect(.replace))
            TextField(L(savedAt == nil ? "Быстрая заметка…" : "Сохранено в Usin"), text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(save)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.06)))
    }

    private func save() {
        guard QuickNote.save(text) != nil else { return }
        text = ""
        let now = Date()
        withAnimation(Motion.hover) { savedAt = now }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if savedAt == now { withAnimation(Motion.hover) { savedAt = nil } }
        }
    }
}

#if os(macOS)
import Foundation
import SwiftData
import UsinTools

/// Заметки, которые пишут инструменты Mac: расшифровки встреч, диктовки, записи из буфера, быстрые заметки.
/// И обратно: ИИ-сервисы инструментов получают заметки, отмеченные «Для ИИ».
extension Workspace {
    func installToolNotes() {
        ToolsHost.writeNote = { [weak self] note, mode in self?.writeToolNote(note, mode: mode) }
        ToolsHost.hasNote = { [weak self] id in
            guard let node = self?.node(id) else { return false }
            return node.deletedAt == nil
        }
        ToolsHost.openNote = { [weak self] id in
            guard let self, let node = self.node(id), node.deletedAt == nil else { return }
            StatusItemController.shared.showWindow()
            self.open(node)
        }
        ToolsHost.notesForAI = { [weak self] limit in self?.notesForAI(limit: limit) ?? ("", 0) }
    }

    /// Создаёт заметку или обновляет её. Строки, которые не изменились, остаются теми же блоками —
    /// синхронизация не гоняет весь текст встречи заново, а открытая заметка не прыгает.
    func writeToolNote(_ note: ToolNote, mode: ToolNote.Mode) -> UUID? {
        var target = node(note.id)
        if let existing = target, existing.deletedAt != nil {
            // Заметку удалили: встречу не возвращаем из корзины, а диктовки начинают новую заметку.
            guard mode == .append else { return nil }
            target = nil
        }

        // Правки инструментов не должны попадать в ⌘Z на холсте.
        context.undoManager?.disableUndoRegistration()
        defer { context.undoManager?.enableUndoRegistration() }

        let node: Node
        if let target {
            node = target
        } else {
            node = Node(position: viewCenterPoint())
            // Id из корзины занят — тогда у новой заметки свой.
            if self.node(note.id) == nil { node.id = note.id }
            node.shape = AppSettings.shared.defaultShape
            if node.shape == .sticker { node.fillIndex = 3 }
            node.title = note.title
            context.insert(node)
        }

        var rows: [(kind: BlockKind, text: String, image: Data?)] = []
        if let image = note.image { rows.append((.image, "", image)) }
        rows += note.lines.map { (.text, $0, nil) }

        switch mode {
        case .replace:
            var blocks = node.sortedBlocks
            for (index, row) in rows.enumerated() {
                let block = index < blocks.count ? blocks[index] : node.addBlock(row.kind, context: context)
                set(block, to: row)
            }
            if blocks.count > rows.count {
                for block in blocks[rows.count...] { node.remove(block, context: context) }
            }
            blocks = node.sortedBlocks
            if blocks.isEmpty { node.addBlock(.text, context: context) }
        case .append:
            // Пустая строка в конце (её получает каждая новая заметка) не нужна.
            if let last = node.sortedBlocks.last, last.kind == .text, last.text.isEmpty {
                node.remove(last, context: context)
            }
            for row in rows { set(node.addBlock(row.kind, context: context), to: row) }
        }
        try? context.save()
        return node.id
    }

    private func set(_ block: NoteBlock, to row: (kind: BlockKind, text: String, image: Data?)) {
        if block.kind != row.kind { block.kind = row.kind }
        if block.text != row.text { block.text = row.text }
        if row.kind == .image, block.imageData != row.image { block.setImage(row.image) }
        if row.kind != .image, block.imageData != nil { block.setImage(nil) }
    }

    /// Заметки «Для ИИ» одним текстом: сначала новые, всего не длиннее `limit` знаков.
    func notesForAI(limit: Int) -> (text: String, count: Int) {
        let descriptor = FetchDescriptor<Node>(
            predicate: #Predicate { $0.isForAI && $0.deletedAt == nil && !$0.isRoot },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let nodes = (try? context.fetch(descriptor)) ?? []
        guard limit > 0 else { return ("", nodes.count) }
        var text = ""
        for node in nodes {
            let body = node.sortedBlocks
                .filter { $0.kind != .image && $0.kind != .divider && !$0.text.isEmpty }
                .map(\.text)
                .joined(separator: "\n")
            let piece = "## \(node.displayTitle)\n\(body)\n\n"
            if text.count + piece.count > limit {
                text += piece.prefix(max(limit - text.count, 0))
                break
            }
            text += piece
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nodes.count)
    }
}
#endif

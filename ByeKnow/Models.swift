import Foundation
import SwiftData
import SwiftUI

// MARK: - Enums

enum NodeShape: String, CaseIterable, Identifiable {
    case card, circle, square, sticker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .card: tr("Карточка")
        case .circle: tr("Круг")
        case .square: tr("Квадрат")
        case .sticker: tr("Стикер")
        }
    }

    var icon: String {
        switch self {
        case .card: "rectangle"
        case .circle: "circle"
        case .square: "square"
        case .sticker: "note.text"
        }
    }

    var size: CGSize {
        switch self {
        case .card: CGSize(width: 200, height: 84)
        case .circle: CGSize(width: 140, height: 140)
        case .square: CGSize(width: 150, height: 150)
        case .sticker: CGSize(width: 170, height: 160)
        }
    }

    var outline: AnyShape {
        switch self {
        case .circle: AnyShape(Circle())
        case .card: AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        case .square: AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .sticker: AnyShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }
}

enum BlockKind: String, CaseIterable, Identifiable {
    case text, heading, checklist, image, link, divider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: tr("Текст")
        case .heading: tr("Заголовок")
        case .checklist: tr("Чек-лист")
        case .image: tr("Картинка")
        case .link: tr("Ссылка")
        case .divider: tr("Разделитель")
        }
    }

    var icon: String {
        switch self {
        case .text: "text.alignleft"
        case .heading: "textformat.size"
        case .checklist: "checklist"
        case .image: "photo"
        case .link: "link"
        case .divider: "minus"
        }
    }
}

enum EdgeStyle: String, CaseIterable, Identifiable {
    case straight, curved

    var id: String { rawValue }
    var title: String { self == .straight ? tr("Прямая") : tr("Изогнутая") }
    var icon: String { self == .straight ? "line.diagonal" : "point.topleft.down.to.point.bottomright.curvepath" }
}

enum EdgeHead: String, CaseIterable, Identifiable {
    case arrow, dot, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: tr("Стрелка")
        case .dot: tr("Точка")
        case .none: tr("Без наконечника")
        }
    }

    var icon: String {
        switch self {
        case .arrow: "arrow.right"
        case .dot: "circle.fill"
        case .none: "minus"
        }
    }
}

// MARK: - Models

@Model
final class Theme {
    var id: UUID = UUID()
    var name: String = ""
    var colorIndex: Int = 1
    var order: Int = 0
    @Relationship(deleteRule: .nullify, inverse: \Node.theme)
    var nodes: [Node] = []

    init(name: String, colorIndex: Int, order: Int) {
        self.name = name
        self.colorIndex = colorIndex
        self.order = order
    }
}

@Model
final class Node {
    var id: UUID = UUID()
    var title: String = ""
    var x: Double = 0
    var y: Double = 0
    var shapeRaw: String = "card"
    var fillIndex: Int = 0
    var inkIndex: Int = 0
    var isRoot: Bool = false
    var createdAt: Date = Date()
    var theme: Theme?
    @Relationship(deleteRule: .cascade, inverse: \NoteBlock.node)
    var blocks: [NoteBlock] = []

    init(position: CGPoint) {
        x = position.x
        y = position.y
    }

    /// У сферы ByeKnow один и тот же id на всех устройствах — так синхронизация не плодит две сферы.
    static let rootID = UUID(uuidString: "B1E0B1E0-0000-4000-8000-000000000001")!

    var shape: NodeShape {
        get { NodeShape(rawValue: shapeRaw) ?? .card }
        set { shapeRaw = newValue.rawValue }
    }

    var position: CGPoint { CGPoint(x: x, y: y) }

    var size: CGSize { isRoot ? CGSize(width: 170, height: 170) : shape.size }

    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var displayTitle: String { hasTitle ? title : tr("Новая заметка") }

    var sortedBlocks: [NoteBlock] { blocks.sorted { $0.order < $1.order } }

    var preview: String {
        sortedBlocks.first { ($0.kind == .text || $0.kind == .checklist) && !$0.text.isEmpty }?.text ?? ""
    }

    func contains(_ point: CGPoint) -> Bool {
        abs(point.x - x) <= size.width / 2 && abs(point.y - y) <= size.height / 2
    }

    // MARK: Blocks

    @discardableResult
    func addBlock(_ kind: BlockKind, after block: NoteBlock? = nil, context: ModelContext) -> NoteBlock {
        var list = sortedBlocks
        let new = NoteBlock(kind: kind)
        context.insert(new)
        blocks.append(new)
        let index = block.flatMap { b in list.firstIndex { $0.id == b.id } }.map { $0 + 1 } ?? list.count
        list.insert(new, at: index)
        renumber(list)
        return new
    }

    /// Переставить строку на позицию `index` (среди остальных строк).
    func moveBlock(_ block: NoteBlock, to index: Int) {
        var list = sortedBlocks.filter { $0.id != block.id }
        list.insert(block, at: min(max(index, 0), list.count))
        renumber(list)
    }

    func remove(_ block: NoteBlock, context: ModelContext) {
        blocks.removeAll { $0.id == block.id }
        context.delete(block)
        renumber(sortedBlocks)
    }

    private func renumber(_ list: [NoteBlock]) {
        for (i, b) in list.enumerated() where b.order != i { b.order = i }
    }
}

@Model
final class NoteBlock {
    var id: UUID = UUID()
    var order: Int = 0
    var kindRaw: String = "text"
    var text: String = ""
    var isChecked: Bool = false
    @Attribute(.externalStorage) var imageData: Data?
    /// Отпечаток картинки — чтобы при синхронизации не читать и не пересчитывать картинки каждый раз.
    var imageHash: String?
    var node: Node?

    init(kind: BlockKind) {
        kindRaw = kind.rawValue
    }

    var kind: BlockKind {
        get { BlockKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    /// Поставить или убрать картинку (вместе с её отпечатком).
    func setImage(_ data: Data?) {
        imageData = data
        imageHash = data.map(sha256Hex)
    }

    /// Отпечаток картинки; у старых блоков считается один раз и запоминается.
    var storedImageHash: String? {
        if imageHash == nil, kind == .image, let data = imageData {
            imageHash = sha256Hex(data)
        }
        return imageHash
    }

    var url: URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let url = URL(string: s.contains("://") ? s : "https://" + s)
        return url?.host() == nil ? nil : url
    }
}

@Model
final class Connection {
    var id: UUID = UUID()
    var fromID: UUID = UUID()
    var toID: UUID = UUID()
    var styleRaw: String = "straight"
    var headRaw: String = "arrow"
    var dashed: Bool = false
    var colorIndex: Int = 0
    var bendX: Double = 0
    var bendY: Double = 0
    var createdAt: Date = Date()

    init(from: UUID, to: UUID) {
        fromID = from
        toID = to
    }

    var style: EdgeStyle {
        get { EdgeStyle(rawValue: styleRaw) ?? .straight }
        set { styleRaw = newValue.rawValue }
    }

    var head: EdgeHead {
        get { EdgeHead(rawValue: headRaw) ?? .arrow }
        set { headRaw = newValue.rawValue }
    }
}

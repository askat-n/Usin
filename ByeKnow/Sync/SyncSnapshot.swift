import Foundation
import SwiftData
import CryptoKit

// MARK: - Records

protocol SyncRecord: Codable, Equatable {
    var id: UUID { get }
}

struct ThemeRecord: SyncRecord {
    var id: UUID
    var name: String
    var colorIndex: Int
    var order: Int
}

struct NodeRecord: SyncRecord {
    var id: UUID
    var title: String
    var x: Double
    var y: Double
    var shapeRaw: String
    var fillIndex: Int
    var inkIndex: Int
    var isRoot: Bool
    var createdAt: Date
    var themeID: UUID?
    /// В корзине с этого момента.
    var deletedAt: Date?
}

struct BlockRecord: SyncRecord {
    var id: UUID
    var nodeID: UUID?
    var order: Int
    var kindRaw: String
    var text: String
    var isChecked: Bool
    /// Сама картинка лежит на Drive отдельным файлом `img-<hash>`.
    var imageHash: String?
}

struct ConnectionRecord: SyncRecord {
    var id: UUID
    var fromID: UUID
    var toID: UUID
    var styleRaw: String
    var headRaw: String
    var dashed: Bool
    var colorIndex: Int
    var bendX: Double
    var bendY: Double
    var createdAt: Date
}

/// Все заметки одним снимком — так они лежат на Google Drive.
struct SyncSnapshot: Codable, Equatable {
    var version = 1
    var themes: [ThemeRecord] = []
    var nodes: [NodeRecord] = []
    var blocks: [BlockRecord] = []
    var connections: [ConnectionRecord] = []

    /// Есть ли что-то, кроме пустой сферы.
    var hasUserData: Bool {
        !themes.isEmpty || nodes.contains { !$0.isRoot && $0.deletedAt == nil }
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Read from the device

extension SyncSnapshot {
    static func current(in context: ModelContext) -> SyncSnapshot {
        let themes = (try? context.fetch(FetchDescriptor<Theme>())) ?? []
        let nodes = (try? context.fetch(FetchDescriptor<Node>())) ?? []
        let blocks = (try? context.fetch(FetchDescriptor<NoteBlock>())) ?? []
        let connections = (try? context.fetch(FetchDescriptor<Connection>())) ?? []

        var snapshot = SyncSnapshot()
        snapshot.themes = themes.map {
            ThemeRecord(id: $0.id, name: $0.name, colorIndex: $0.colorIndex, order: $0.order)
        }
        snapshot.nodes = nodes.map {
            NodeRecord(id: $0.id, title: $0.title, x: $0.x, y: $0.y, shapeRaw: $0.shapeRaw,
                       fillIndex: $0.fillIndex, inkIndex: $0.inkIndex, isRoot: $0.isRoot,
                       createdAt: $0.createdAt, themeID: $0.theme?.id, deletedAt: $0.deletedAt)
        }
        snapshot.blocks = blocks.map {
            BlockRecord(id: $0.id, nodeID: $0.node?.id, order: $0.order, kindRaw: $0.kindRaw,
                        text: $0.text, isChecked: $0.isChecked, imageHash: $0.storedImageHash)
        }
        snapshot.connections = connections.map {
            ConnectionRecord(id: $0.id, fromID: $0.fromID, toID: $0.toID, styleRaw: $0.styleRaw,
                             headRaw: $0.headRaw, dashed: $0.dashed, colorIndex: $0.colorIndex,
                             bendX: $0.bendX, bendY: $0.bendY, createdAt: $0.createdAt)
        }
        return snapshot.sorted()
    }
}

// MARK: - Cleanup

extension SyncSnapshot {
    /// Убрать «висящие» ссылки: блоки без заметки, стрелки без концов, темы, которых нет.
    func sanitized() -> SyncSnapshot {
        var s = self
        let themeIDs = Set(s.themes.map(\.id))
        for i in s.nodes.indices where s.nodes[i].themeID.map({ !themeIDs.contains($0) }) ?? false {
            s.nodes[i].themeID = nil
        }
        // Сфера должна быть ровно одна.
        s.nodes.removeAll { $0.isRoot && $0.id != Node.rootID }
        let nodeIDs = Set(s.nodes.map(\.id))
        s.blocks.removeAll { $0.nodeID.map { !nodeIDs.contains($0) } ?? true }
        s.connections.removeAll { !nodeIDs.contains($0.fromID) || !nodeIDs.contains($0.toID) }
        return s
    }

    func sorted() -> SyncSnapshot {
        var s = self
        s.themes.sort { $0.id.uuidString < $1.id.uuidString }
        s.nodes.sort { $0.id.uuidString < $1.id.uuidString }
        s.blocks.sort { $0.id.uuidString < $1.id.uuidString }
        s.connections.sort { $0.id.uuidString < $1.id.uuidString }
        return s
    }
}

// MARK: - Write to the device

extension SyncSnapshot {
    /// Привести данные на устройстве к этому снимку. Меняем только то, что отличается.
    /// Возвращает отпечатки картинок, которые нужны, но ещё не скачаны.
    @discardableResult
    func apply(to context: ModelContext, images: [String: Data]) throws -> Set<String> {
        var missing = Set<String>()
        let themes = (try? context.fetch(FetchDescriptor<Theme>())) ?? []
        let nodes = (try? context.fetch(FetchDescriptor<Node>())) ?? []
        let blocks = (try? context.fetch(FetchDescriptor<NoteBlock>())) ?? []
        let connections = (try? context.fetch(FetchDescriptor<Connection>())) ?? []

        // Темы
        var themeByID = Dictionary(themes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for rec in self.themes {
            let theme = themeByID[rec.id] ?? {
                let t = Theme(name: rec.name, colorIndex: rec.colorIndex, order: rec.order)
                t.id = rec.id
                context.insert(t)
                themeByID[rec.id] = t
                return t
            }()
            set(&theme.name, rec.name)
            set(&theme.colorIndex, rec.colorIndex)
            set(&theme.order, rec.order)
        }

        // Заметки
        var nodeByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for rec in self.nodes {
            let node = nodeByID[rec.id] ?? {
                let n = Node(position: CGPoint(x: rec.x, y: rec.y))
                n.id = rec.id
                context.insert(n)
                nodeByID[rec.id] = n
                return n
            }()
            set(&node.title, rec.title)
            set(&node.x, rec.x)
            set(&node.y, rec.y)
            set(&node.shapeRaw, rec.shapeRaw)
            set(&node.fillIndex, rec.fillIndex)
            set(&node.inkIndex, rec.inkIndex)
            set(&node.isRoot, rec.isRoot)
            set(&node.createdAt, rec.createdAt)
            set(&node.deletedAt, rec.deletedAt)
            let theme = rec.themeID.flatMap { themeByID[$0] }
            if node.theme?.id != theme?.id { node.theme = theme }
        }

        // Строки заметок
        var blockByID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for rec in self.blocks {
            let block = blockByID[rec.id] ?? {
                let b = NoteBlock(kind: BlockKind(rawValue: rec.kindRaw) ?? .text)
                b.id = rec.id
                context.insert(b)
                blockByID[rec.id] = b
                return b
            }()
            set(&block.order, rec.order)
            set(&block.kindRaw, rec.kindRaw)
            set(&block.text, rec.text)
            set(&block.isChecked, rec.isChecked)
            if block.imageHash != rec.imageHash {
                if let hash = rec.imageHash, let data = images[hash] {
                    block.setImage(data)
                } else {
                    // Картинка ещё не скачана — запоминаем, какая нужна, докачаем позже.
                    block.imageData = nil
                    block.imageHash = rec.imageHash
                    if let hash = rec.imageHash { missing.insert(hash) }
                }
            }
            let owner = rec.nodeID.flatMap { nodeByID[$0] }
            if block.node?.id != owner?.id { block.node = owner }
        }

        // Стрелки
        var connectionByID = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for rec in self.connections {
            let c = connectionByID[rec.id] ?? {
                let c = Connection(from: rec.fromID, to: rec.toID)
                c.id = rec.id
                context.insert(c)
                connectionByID[rec.id] = c
                return c
            }()
            set(&c.fromID, rec.fromID)
            set(&c.toID, rec.toID)
            set(&c.styleRaw, rec.styleRaw)
            set(&c.headRaw, rec.headRaw)
            set(&c.dashed, rec.dashed)
            set(&c.colorIndex, rec.colorIndex)
            set(&c.bendX, rec.bendX)
            set(&c.bendY, rec.bendY)
            set(&c.createdAt, rec.createdAt)
        }

        // Удалить то, чего больше нет
        let keepConnections = Set(self.connections.map(\.id))
        for c in connections where !keepConnections.contains(c.id) { context.delete(c) }
        let keepBlocks = Set(self.blocks.map(\.id))
        for b in blocks where !keepBlocks.contains(b.id) { context.delete(b) }
        let keepNodes = Set(self.nodes.map(\.id))
        for n in nodes where !keepNodes.contains(n.id) { context.delete(n) }
        let keepThemes = Set(self.themes.map(\.id))
        for t in themes where !keepThemes.contains(t.id) { context.delete(t) }

        if context.hasChanges { try context.save() }
        return missing
    }
}

/// Присваивать только при отличии — чтобы не плодить лишних изменений и синхронизаций.
private func set<T: Equatable>(_ target: inout T, _ value: T) {
    if target != value { target = value }
}

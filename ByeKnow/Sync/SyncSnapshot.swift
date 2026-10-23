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
        !themes.isEmpty || nodes.contains { !$0.isRoot }
    }
}

func imageHash(_ data: Data) -> String {
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
                       createdAt: $0.createdAt, themeID: $0.theme?.id)
        }
        snapshot.blocks = blocks.map {
            BlockRecord(id: $0.id, nodeID: $0.node?.id, order: $0.order, kindRaw: $0.kindRaw,
                        text: $0.text, isChecked: $0.isChecked, imageHash: $0.imageData.map(imageHash))
        }
        snapshot.connections = connections.map {
            ConnectionRecord(id: $0.id, fromID: $0.fromID, toID: $0.toID, styleRaw: $0.styleRaw,
                             headRaw: $0.headRaw, dashed: $0.dashed, colorIndex: $0.colorIndex,
                             bendX: $0.bendX, bendY: $0.bendY, createdAt: $0.createdAt)
        }
        return snapshot.sorted()
    }

    static func localImages(in context: ModelContext) -> [String: Data] {
        let blocks = (try? context.fetch(FetchDescriptor<NoteBlock>())) ?? []
        var result: [String: Data] = [:]
        for block in blocks {
            if let data = block.imageData { result[imageHash(data)] = data }
        }
        return result
    }
}

// MARK: - Merge

extension SyncSnapshot {
    /// Трёхстороннее слияние: base — что было после прошлой синхронизации.
    /// Изменилось только на одной стороне — берём эту сторону.
    /// Изменилось на обеих — правка этого устройства, но удаление никогда не побеждает правку.
    static func merge(base: SyncSnapshot, local: SyncSnapshot, remote: SyncSnapshot) -> SyncSnapshot {
        var merged = SyncSnapshot()
        merged.themes = mergeRecords(base.themes, local.themes, remote.themes)
        merged.nodes = mergeRecords(base.nodes, local.nodes, remote.nodes)
        merged.blocks = mergeRecords(base.blocks, local.blocks, remote.blocks)
        merged.connections = mergeRecords(base.connections, local.connections, remote.connections)
        return merged.sanitized().sorted()
    }

    private static func mergeRecords<R: SyncRecord>(_ base: [R], _ local: [R], _ remote: [R]) -> [R] {
        let b = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let l = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let r = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [R] = []
        for id in Set(b.keys).union(l.keys).union(r.keys) {
            let bv = b[id], lv = l[id], rv = r[id]
            let pick: R?
            if lv == bv {
                pick = rv
            } else if rv == bv {
                pick = lv
            } else if bv == nil {
                pick = rv ?? lv // новое на обеих сторонах — побеждает Drive
            } else {
                pick = lv ?? rv
            }
            if let pick { result.append(pick) }
        }
        return result
    }

    /// Убрать «висящие» ссылки: блоки без заметки, стрелки без концов, темы, которых нет.
    func sanitized() -> SyncSnapshot {
        var s = self
        let themeIDs = Set(s.themes.map(\.id))
        for i in s.nodes.indices where s.nodes[i].themeID.map({ !themeIDs.contains($0) }) ?? false {
            s.nodes[i].themeID = nil
        }
        // Сфера должна быть ровно одна.
        if let firstRoot = s.nodes.first(where: \.isRoot)?.id {
            s.nodes.removeAll { $0.isRoot && $0.id != firstRoot }
        }
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

    /// Каждое устройство при первом запуске создаёт свою сферу.
    /// Берём сферу с Drive, чтобы их не стало две.
    mutating func adoptRoot(from remote: SyncSnapshot) {
        guard let remoteRoot = remote.nodes.first(where: \.isRoot),
              let index = nodes.firstIndex(where: \.isRoot),
              nodes[index].id != remoteRoot.id else { return }
        let old = nodes[index].id
        nodes[index].id = remoteRoot.id
        for i in connections.indices {
            if connections[i].fromID == old { connections[i].fromID = remoteRoot.id }
            if connections[i].toID == old { connections[i].toID = remoteRoot.id }
        }
        for i in blocks.indices where blocks[i].nodeID == old { blocks[i].nodeID = remoteRoot.id }
    }
}

// MARK: - Write to the device

extension SyncSnapshot {
    /// Привести данные на устройстве к этому снимку. Меняем только то, что отличается.
    func apply(to context: ModelContext, images: [String: Data]) throws {
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
            if block.imageData.map(imageHash) != rec.imageHash {
                block.imageData = rec.imageHash.flatMap { images[$0] }
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
    }
}

/// Присваивать только при отличии — чтобы не плодить лишних изменений и синхронизаций.
private func set<T: Equatable>(_ target: inout T, _ value: T) {
    if target != value { target = value }
}

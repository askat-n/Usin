import Foundation

/// Запись и время её последнего изменения. `record == nil` — запись удалена.
struct Entry<R: SyncRecord>: Codable, Equatable {
    var record: R?
    var updatedAt: Date
}

/// Журнал устройства: все записи со временем изменения.
/// Каждое устройство хранит на Drive свой журнал в своём файле и пишет только в него,
/// поэтому два устройства не могут затереть правки друг друга.
/// Объединение: по каждой записи побеждает самое свежее изменение (в том числе удаление).
struct Ledger: Codable, Equatable {
    var version = 2
    var themes: [UUID: Entry<ThemeRecord>] = [:]
    var nodes: [UUID: Entry<NodeRecord>] = [:]
    var blocks: [UUID: Entry<BlockRecord>] = [:]
    var connections: [UUID: Entry<ConnectionRecord>] = [:]

    /// Особые «старые» отметки времени для первого запуска новой синхронизации.
    static let freshRootStamp = Date(timeIntervalSince1970: 1)
    static let staleCopyStamp = Date(timeIntervalSince1970: 2)
    static let legacyStamp = Date(timeIntervalSince1970: 3)

    /// Живые (не удалённые) записи.
    var snapshot: SyncSnapshot {
        var s = SyncSnapshot()
        s.themes = themes.values.compactMap(\.record)
        s.nodes = nodes.values.compactMap(\.record)
        s.blocks = blocks.values.compactMap(\.record)
        s.connections = connections.values.compactMap(\.record)
        return s.sanitized().sorted()
    }

    var hasUserData: Bool { snapshot.hasUserData }

    // MARK: - Recording local changes

    /// Отметить, что на устройстве изменилось с прошлого раза.
    /// `firstStamp` решает, какое время поставить записи, которую журнал видит впервые.
    mutating func record(_ local: SyncSnapshot, now: Date, firstStamp: (any SyncRecord) -> Date) {
        Self.stamp(&themes, local.themes, now: now, firstStamp: firstStamp)
        Self.stamp(&nodes, local.nodes, now: now, firstStamp: firstStamp)
        Self.stamp(&blocks, local.blocks, now: now, firstStamp: firstStamp)
        Self.stamp(&connections, local.connections, now: now, firstStamp: firstStamp)
    }

    private static func stamp<R: SyncRecord>(_ entries: inout [UUID: Entry<R>], _ local: [R], now: Date,
                                             firstStamp: (any SyncRecord) -> Date) {
        var seen = Set<UUID>()
        for rec in local {
            seen.insert(rec.id)
            if let existing = entries[rec.id] {
                if existing.record != rec { entries[rec.id] = Entry(record: rec, updatedAt: now) }
            } else {
                entries[rec.id] = Entry(record: rec, updatedAt: firstStamp(rec))
            }
        }
        // Были, а теперь нет — значит, удалили на этом устройстве.
        for (id, entry) in entries where entry.record != nil && !seen.contains(id) {
            entries[id] = Entry(record: nil, updatedAt: now)
        }
    }

    // MARK: - Merge

    /// Объединить журналы: по каждой записи — самое свежее изменение.
    static func merge(_ ledgers: [Ledger]) -> Ledger {
        var result = Ledger()
        for ledger in ledgers {
            mergeEntries(&result.themes, ledger.themes)
            mergeEntries(&result.nodes, ledger.nodes)
            mergeEntries(&result.blocks, ledger.blocks)
            mergeEntries(&result.connections, ledger.connections)
        }
        return result
    }

    private static func mergeEntries<R: SyncRecord>(_ into: inout [UUID: Entry<R>], _ other: [UUID: Entry<R>]) {
        for (id, entry) in other {
            guard let current = into[id] else {
                into[id] = entry
                continue
            }
            if entry.updatedAt > current.updatedAt {
                into[id] = entry
            } else if entry.updatedAt == current.updatedAt, current.record == nil, entry.record != nil {
                into[id] = entry // при равном времени сохраняем данные, а не удаление
            }
        }
    }

    // MARK: - Old format

    /// Общий файл первой версии синхронизации → журнал с «старыми» отметками.
    init(legacy snapshot: SyncSnapshot) {
        var s = snapshot
        s.remapRoot()
        for r in s.themes { themes[r.id] = Entry(record: r, updatedAt: Self.legacyStamp) }
        for r in s.nodes { nodes[r.id] = Entry(record: r, updatedAt: Self.legacyStamp) }
        for r in s.blocks { blocks[r.id] = Entry(record: r, updatedAt: Self.legacyStamp) }
        for r in s.connections { connections[r.id] = Entry(record: r, updatedAt: Self.legacyStamp) }
    }

    init() {}
}

extension SyncSnapshot {
    /// В первой версии у сферы на каждом устройстве был свой случайный id — приводим к общему.
    mutating func remapRoot() {
        guard let index = nodes.firstIndex(where: \.isRoot) else { return }
        let old = nodes[index].id
        guard old != Node.rootID else { return }
        nodes.removeAll { $0.isRoot && $0.id != old }
        let i = nodes.firstIndex { $0.id == old }!
        nodes[i].id = Node.rootID
        for c in connections.indices {
            if connections[c].fromID == old { connections[c].fromID = Node.rootID }
            if connections[c].toID == old { connections[c].toID = Node.rootID }
        }
        for b in blocks.indices where blocks[b].nodeID == old { blocks[b].nodeID = Node.rootID }
    }

}

import Foundation

/// Одна заметка из папки, которую держит ByeKnow.
struct Note {
    let path: String          // относительно папки, например «Работа/План.md»
    let name: String          // имя файла без .md — то, что пишут в [[ссылках]]
    let meta: [String: Any]
    let body: String
    let raw: String

    var id: String? { meta["id"] as? String }
    var title: String { (meta["title"] as? String) ?? name }
    var theme: String? {
        if let t = meta["theme"] as? String, !t.isEmpty { return t }
        let parts = path.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : nil
    }
    var color: String? { meta["color"] as? String }
    var created: String? { meta["created"] as? String }
    var linksTo: [String] { Vault.links(meta["links_to"]) }
    var linkedFrom: [String] { Vault.links(meta["linked_from"]) }

    var summary: [String: Any] {
        var d: [String: Any] = ["title": title, "path": path]
        if let theme { d["theme"] = theme }
        if let color { d["color"] = color }
        if let created { d["created"] = created }
        if let id { d["id"] = id }
        if !linksTo.isEmpty { d["links_to"] = linksTo }
        if !linkedFrom.isEmpty { d["linked_from"] = linkedFrom }
        return d
    }
}

enum VaultError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "" }
}

/// Папка с заметками ByeKnow в Markdown.
struct Vault {
    static let inbox = "inbox"
    static let attachments = "attachments"
    static let colors = ["default", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]

    let root: URL

    func notes() throws -> [Note] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw VaultError.message("Папка с заметками не найдена: \(root.path). Включи «Заметки в папке Markdown» в Настройках ByeKnow и укажи ту же папку в конфиге MCP.")
        }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [Note] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in e {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            let rel = String(full.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let top = rel.split(separator: "/").first.map(String.init) ?? ""
            if top == Self.inbox || top == Self.attachments {
                e.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (meta, body) = Self.parseFrontMatter(text)
            result.append(Note(path: rel, name: url.deletingPathExtension().lastPathComponent, meta: meta, body: body, raw: text))
        }
        return result.sorted { ($0.created ?? "", $0.path) > ($1.created ?? "", $1.path) }
    }

    /// Заметка по пути, id, имени файла, названию или `[[ссылке]]`.
    func find(_ ref: String) throws -> Note {
        let all = try notes()
        var key = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("[["), key.hasSuffix("]]") { key = String(key.dropFirst(2).dropLast(2)) }
        let lower = key.lowercased()
        let withMd = lower.hasSuffix(".md") ? lower : lower + ".md"
        if let n = all.first(where: { $0.path.lowercased() == withMd }) { return n }
        if let n = all.first(where: { $0.id?.lowercased() == lower }) { return n }
        if let n = all.first(where: { $0.name.lowercased() == lower }) { return n }
        if let n = all.first(where: { $0.title.lowercased() == lower }) { return n }
        let partial = all.filter { $0.title.lowercased().contains(lower) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 {
            throw VaultError.message("Под «\(key)» подходит несколько заметок: " + partial.prefix(10).map { "\($0.title) (\($0.path))" }.joined(separator: "; ") + ". Уточни путь.")
        }
        throw VaultError.message("Заметка «\(key)» не найдена. Используй search_notes или list_notes.")
    }

    /// Новая заметка — файл во `inbox/`; ByeKnow (если открыт) сам превратит его в заметку.
    func createNote(title: String, body: String, theme: String?, color: String?, linksTo: [String]) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            throw VaultError.message("Папка с заметками не найдена: \(root.path)")
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw VaultError.message("Нужно название заметки (title).") }
        if let color, !Self.colors.contains(color.lowercased()) {
            throw VaultError.message("Неизвестный цвет «\(color)». Можно: " + Self.colors.joined(separator: ", "))
        }
        var head = ["---", "title: \(Self.quote(cleanTitle))"]
        if let theme, !theme.trimmingCharacters(in: .whitespaces).isEmpty { head.append("theme: \(Self.quote(theme))") }
        if let color { head.append("color: \(color.lowercased())") }
        if !linksTo.isEmpty { head.append("links_to: [\(linksTo.map { Self.quote($0) }.joined(separator: ", "))]") }
        head.append("---")
        let text = head.joined(separator: "\n") + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

        let inbox = root.appendingPathComponent(Self.inbox, isDirectory: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let slug = String(cleanTitle.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#\n\r\t")).joined(separator: " ").prefix(60))
        let name = "\(stamp)-\(UUID().uuidString.prefix(6)) \(slug).md"
        // Сначала скрытый файл, потом переименование — чтобы ByeKnow не прочитал его наполовину.
        let tmp = inbox.appendingPathComponent("." + name + ".tmp")
        try Data(text.utf8).write(to: tmp)
        let dest = inbox.appendingPathComponent(name)
        try fm.moveItem(at: tmp, to: dest)
        return "\(Self.inbox)/\(name)"
    }

    // MARK: - Разбор

    static func parseFrontMatter(_ text: String) -> ([String: Any], String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        var meta: [String: Any] = [:]
        var listKey: String?
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let key = listKey, trimmed.hasPrefix("- ") {
                var list = meta[key] as? [String] ?? []
                list.append(unquote(String(trimmed.dropFirst(2))))
                meta[key] = list
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            listKey = nil
            if value.isEmpty {
                listKey = key
                meta[key] = [String]()
            } else if value.hasPrefix("["), let list = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [Any] {
                meta[key] = list.map { "\($0)" }
            } else if value.hasPrefix("[") {
                meta[key] = value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }
            } else {
                meta[key] = unquote(value)
            }
        }
        return (meta, lines[(end + 1)...].joined(separator: "\n"))
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), let v = try? JSONSerialization.jsonObject(with: Data(t.utf8), options: .fragmentsAllowed) as? String {
            return v
        }
        if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") { return String(t.dropFirst().dropLast()) }
        return t
    }

    static func links(_ value: Any?) -> [String] {
        let list = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
        return list.map {
            var s = $0.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("[["), s.hasSuffix("]]") { s = String(s.dropFirst(2).dropLast(2)) }
            return s
        }.filter { !$0.isEmpty }
    }

    static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

import Foundation

/// Одна заметка из папки, которую держит ByeKnow.
struct Note {
    let path: String          // относительно папки, например «Работа/План.md»
    let name: String          // имя файла без .md — уникально, его пишут в [[ссылках]]
    let title: String
    let theme: String?
    let created: String
    let linksTo: [String]
    let linkedFrom: [String]
    /// Текст без шапки, без строки «# Название» и с картинками вместо длинных путей.
    let body: String

    /// Первая строка текста — короткое превью.
    var preview: String {
        let line = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" } ?? ""
        return Tools.clip(line, 70)
    }

    /// Ярлык темы для вывода.
    var themeLabel: String { theme ?? "без темы" }
}

enum VaultError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "" }
}

/// Папка с заметками ByeKnow в Markdown. Разобранные файлы кэшируются по дате изменения.
final class Vault {
    static let inbox = "inbox"
    static let attachments = "attachments"
    static let colors = ["default", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]

    let root: URL
    private var cache: [String: (date: Date, note: Note)] = [:]

    init(root: URL) { self.root = root }

    func notes() throws -> [Note] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw VaultError.message("Папка с заметками не найдена: \(root.path). Включи «Заметки в папке Markdown» в Настройках ByeKnow и укажи ту же папку в конфиге MCP.")
        }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [Note] = []
        var seen: Set<String> = []
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
            guard url.pathExtension.lowercased() == "md" else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            seen.insert(rel)
            if let hit = cache[rel], hit.date == date {
                result.append(hit.note)
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let note = Self.parse(text, path: rel, name: url.deletingPathExtension().lastPathComponent)
            cache[rel] = (date, note)
            result.append(note)
        }
        cache = cache.filter { seen.contains($0.key) }
        return result.sorted { ($0.created, $0.path) > ($1.created, $1.path) }
    }

    /// Заметка по имени, пути, названию, `[[ссылке]]` или id.
    func find(_ ref: String, in all: [Note]? = nil) throws -> Note {
        let all = try all ?? notes()
        var key = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("[["), key.hasSuffix("]]") { key = String(key.dropFirst(2).dropLast(2)) }
        let lower = key.lowercased()
        let withMd = lower.hasSuffix(".md") ? lower : lower + ".md"
        if let n = all.first(where: { $0.name.lowercased() == lower }) { return n }
        if let n = all.first(where: { $0.path.lowercased() == withMd }) { return n }
        if let n = all.first(where: { $0.title.lowercased() == lower }) { return n }
        let partial = all.filter { $0.name.lowercased().contains(lower) || $0.title.lowercased().contains(lower) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 {
            throw VaultError.message("Подходят несколько: " + partial.prefix(10).map(\.name).joined(separator: "; ") + ". Укажи точное имя.")
        }
        throw VaultError.message("Заметка «\(key)» не найдена. Попробуй search_notes.")
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
        try fm.moveItem(at: tmp, to: inbox.appendingPathComponent(name))
        return "\(Self.inbox)/\(name)"
    }

    // MARK: - Разбор

    static func parse(_ text: String, path: String, name: String) -> Note {
        let (meta, rawBody) = parseFrontMatter(text)
        let title = (meta["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        var theme = meta["theme"] as? String
        if theme?.isEmpty ?? true {
            let parts = path.split(separator: "/")
            theme = parts.count > 1 ? String(parts[0]) : nil
        }
        return Note(
            path: path,
            name: name,
            title: title,
            theme: theme,
            created: meta["created"] as? String ?? "",
            linksTo: links(meta["links_to"]),
            linkedFrom: links(meta["linked_from"]),
            body: cleanBody(rawBody, title: title)
        )
    }

    /// Убирает то, что не несёт смысла для ИИ: повтор названия, длинные пути картинок, лишние пустые строки.
    static func cleanBody(_ body: String, title: String) -> String {
        var lines = body.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# ") {
            lines.remove(at: first)
        }
        var out: [String] = []
        for line in lines {
            let t = line.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "[картинка]", options: .regularExpression)
            if t.trimmingCharacters(in: .whitespaces).isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(t.trimmingCharacters(in: .whitespaces).isEmpty ? "" : t)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

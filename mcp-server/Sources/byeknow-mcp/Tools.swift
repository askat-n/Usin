import Foundation

/// Инструменты MCP поверх папки с заметками.
///
/// Всё отдаётся коротким текстом, а не JSON: меньше токенов.
/// Схема для ИИ: карта (overview) → поиск или список темы → соседи по стрелкам → нужный раздел заметки.
/// Заметку везде называют по имени файла — оно короткое и уникальное.
struct Tools {
    let vault: Vault

    nonisolated(unsafe) static let definitions: [[String: Any]] = [
        [
            "name": "overview",
            "description": "Карта заметок: темы с числом заметок, главные узлы (больше всего стрелок), новые. Вызывай первым.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "list_notes",
            "description": "Имена заметок по темам (новые сверху). Только имена; detail=true — с превью.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "theme": ["type": "string", "description": "Тема; \"\" — без темы"],
                    "detail": ["type": "boolean"],
                    "offset": ["type": "integer"],
                    "limit": ["type": "integer", "description": "По умолчанию 200 (с detail — 30)"],
                ],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "search_notes",
            "description": "Поиск по названиям и тексту. Возвращает имена и короткие отрывки, не целые заметки.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "theme": ["type": "string"],
                    "limit": ["type": "integer", "description": "По умолчанию 8"],
                ],
                "required": ["query"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "related_notes",
            "description": "Соседи заметки: куда ведут её стрелки (→), откуда приходят (←) и та же тема — с превью.",
            "inputSchema": [
                "type": "object",
                "properties": ["note": ["type": "string", "description": "Имя заметки"]],
                "required": ["note"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "read_note",
            "description": "Текст заметки. Длинную читай частями: outline=true — оглавление, section — один раздел.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "note": ["type": "string", "description": "Имя заметки"],
                    "outline": ["type": "boolean"],
                    "section": ["type": "string", "description": "Заголовок раздела"],
                    "max_chars": ["type": "integer", "description": "По умолчанию 3000"],
                ],
                "required": ["note"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "create_note",
            "description": "Новая заметка в ByeKnow (появится на холсте, когда приложение открыто). Существующие не меняет. В body каждая строка — блок: «## » заголовок, «- [ ] » чек-лист, «---», строка-ссылка.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "body": ["type": "string"],
                    "theme": ["type": "string", "description": "Нет такой — будет создана"],
                    "color": ["type": "string", "enum": Vault.colors],
                    "links_to": ["type": "array", "items": ["type": "string"], "description": "Имена заметок для стрелок"],
                ],
                "required": ["title"],
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false],
        ],
    ]

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "overview", "list_themes": return try overview()
        case "list_notes":
            let detail = args["detail"] as? Bool ?? false
            return try listNotes(
                theme: args["theme"] as? String,
                detail: detail,
                offset: Self.int(args["offset"]) ?? 0,
                limit: Self.int(args["limit"]) ?? (detail ? 30 : 200)
            )
        case "search_notes":
            guard let q = args["query"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw VaultError.message("Нужен query.")
            }
            return try search(q, theme: args["theme"] as? String, limit: Self.int(args["limit"]) ?? 8)
        case "related_notes":
            guard let ref = args["note"] as? String else { throw VaultError.message("Нужен note.") }
            return try related(ref)
        case "read_note":
            guard let ref = args["note"] as? String else { throw VaultError.message("Нужен note.") }
            return try read(ref, outline: args["outline"] as? Bool ?? false,
                            section: args["section"] as? String, maxChars: Self.int(args["max_chars"]) ?? 3000)
        case "create_note":
            let path = try vault.createNote(
                title: args["title"] as? String ?? "",
                body: args["body"] as? String ?? "",
                theme: args["theme"] as? String,
                color: args["color"] as? String,
                linksTo: (args["links_to"] as? [Any])?.compactMap { $0 as? String } ?? []
            )
            return "Передано в ByeKnow (\(path)). Появится на холсте, когда приложение открыто."
        default:
            throw VaultError.message("Неизвестный инструмент: \(name)")
        }
    }

    // MARK: - overview

    private func overview() throws -> String {
        let notes = try vault.notes()
        guard !notes.isEmpty else { return "Заметок нет." }
        let groups = Self.byTheme(notes)
        var out = ["\(notes.count) заметок. Темы: " + groups.map { "\($0.label) (\($0.notes.count))" }.joined(separator: ", ")]
        let degree = notes.map { ($0, $0.linksTo.count + $0.linkedFrom.count) }.filter { $0.1 >= 2 }
            .sorted { $0.1 > $1.1 }.prefix(8)
        if !degree.isEmpty {
            out.append("Узлы: " + degree.map { "\($0.0.name) (\($0.1))" }.joined(separator: ", "))
        }
        out.append("Новые: " + notes.prefix(5).map(\.name).joined(separator: ", "))
        return out.joined(separator: "\n")
    }

    // MARK: - list_notes

    private func listNotes(theme: String?, detail: Bool, offset: Int, limit: Int) throws -> String {
        let notes = filtered(try vault.notes(), theme: theme)
        let start = min(max(offset, 0), notes.count)
        let page = Array(notes[start..<min(start + max(limit, 1), notes.count)])
        var out: [String] = []
        for group in Self.byTheme(page) {
            out.append("## \(group.label)")
            for n in group.notes {
                out.append(detail && !n.preview.isEmpty ? "\(n.name) — \(n.preview)" : n.name)
            }
        }
        let end = start + page.count
        var head = "\(notes.count) заметок"
        if start > 0 || end < notes.count { head += ", показаны \(start + 1)–\(end); дальше: offset=\(end)" }
        return ([head] + out).joined(separator: "\n")
    }

    // MARK: - search_notes

    private func search(_ query: String, theme: String?, limit: Int) throws -> String {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let pool = filtered(try vault.notes(), theme: theme)

        func score(_ n: Note, needAll: Bool) -> Int? {
            let hay = n.name + "\n" + n.title + "\n" + n.body
            let matched = words.filter { hay.range(of: $0, options: opts) != nil }
            if matched.isEmpty || (needAll && matched.count < words.count) { return nil }
            var s = matched.count * 3
            for w in matched {
                if n.name.range(of: w, options: opts) != nil || n.title.range(of: w, options: opts) != nil { s += 10 }
                s += min(n.body.lowercased().components(separatedBy: w).count - 1, 5)
            }
            return s
        }

        var partial = false
        var hits = pool.compactMap { n in score(n, needAll: true).map { ($0, n) } }
        if hits.isEmpty, words.count > 1 {
            hits = pool.compactMap { n in score(n, needAll: false).map { ($0, n) } }
            partial = true
        }
        guard !hits.isEmpty else { return "Ничего не найдено по «\(query)»." }
        hits.sort { $0.0 > $1.0 }

        var out = ["\(hits.count) найдено" + (partial ? " (не все слова сразу)" : "")]
        for (_, n) in hits.prefix(max(limit, 1)) {
            let snip = Self.snippets(n.body, words: words)
            out.append("\(n.name) [\(n.themeLabel)]" + (snip.isEmpty ? "" : ": " + snip.joined(separator: " | ")))
        }
        if hits.count > limit { out.append("…ещё \(hits.count - limit); уточни запрос или theme") }
        return out.joined(separator: "\n")
    }

    // MARK: - related_notes

    private func related(_ ref: String) throws -> String {
        let all = try vault.notes()
        let note = try vault.find(ref, in: all)
        let byName = Dictionary(all.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        func line(_ prefix: String, _ name: String) -> String {
            let p = byName[name.lowercased()]?.preview ?? ""
            return "\(prefix) \(name)" + (p.isEmpty ? "" : " — \(p)")
        }
        var out = ["\(note.name) [\(note.themeLabel)]"]
        out += note.linksTo.map { line("→", $0) }
        out += note.linkedFrom.map { line("←", $0) }
        if note.linksTo.isEmpty, note.linkedFrom.isEmpty { out.append("Стрелок нет.") }
        if let theme = note.theme {
            let linked = Set((note.linksTo + note.linkedFrom).map { $0.lowercased() })
            let same = all.filter { $0.theme == theme && $0.name != note.name && !linked.contains($0.name.lowercased()) }
            if !same.isEmpty {
                out.append("Тема \(theme): " + same.prefix(12).map(\.name).joined(separator: ", ")
                           + (same.count > 12 ? " …ещё \(same.count - 12)" : ""))
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - read_note

    private func read(_ ref: String, outline: Bool, section: String?, maxChars: Int) throws -> String {
        let note = try vault.find(ref)
        var head = "\(note.name) [\(note.themeLabel)]"
        if note.title != note.name { head += " «\(note.title)»" }
        if !note.linksTo.isEmpty { head += " → " + note.linksTo.joined(separator: ", ") }
        if !note.linkedFrom.isEmpty { head += " ← " + note.linkedFrom.joined(separator: ", ") }

        let lines = note.body.components(separatedBy: "\n")
        let headings = lines.enumerated().compactMap { i, l -> (Int, Int, String)? in
            guard let m = l.firstMatch(of: /^(#{1,6})\s+(.+)$/) else { return nil }
            return (i, m.1.count, String(m.2))
        }

        if outline {
            guard !headings.isEmpty else { return head + "\nЗаголовков нет, \(note.body.count) симв." }
            let rows = headings.enumerated().map { k, h -> String in
                let end = k + 1 < headings.count ? headings[k + 1].0 : lines.count
                let size = lines[(h.0 + 1)..<end].joined(separator: "\n").count
                return String(repeating: "  ", count: max(h.1 - 2, 0)) + "\(h.2) (\(size) симв.)"
            }
            return ([head, "Всего \(note.body.count) симв. Разделы:"] + rows).joined(separator: "\n")
        }

        var text = note.body
        if let section {
            let key = section.trimmingCharacters(in: .whitespaces).lowercased()
            guard let k = headings.firstIndex(where: { $0.2.lowercased() == key })
                    ?? headings.firstIndex(where: { $0.2.lowercased().contains(key) }) else {
                return head + "\nРаздел «\(section)» не найден. Есть: " + headings.map(\.2).joined(separator: ", ")
            }
            let (startLine, level, _) = headings[k]
            let end = headings[(k + 1)...].first { $0.1 <= level }?.0 ?? lines.count
            text = lines[startLine..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.isEmpty { text = "(пусто)" }
        if text.count > maxChars {
            let rest = text.count - maxChars
            text = String(text.prefix(maxChars)) + "\n…обрезано, ещё \(rest) симв. — запроси outline/section или больше max_chars"
        }
        return head + "\n\n" + text
    }

    // MARK: - Вспомогательное

    private func filtered(_ notes: [Note], theme: String?) -> [Note] {
        guard let theme else { return notes }
        let t = theme.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "без темы" { return notes.filter { $0.theme == nil } }
        return notes.filter { $0.theme?.compare(t, options: .caseInsensitive) == .orderedSame }
    }

    /// Группы по темам: сначала темы по алфавиту, «без темы» — в конце.
    private static func byTheme(_ notes: [Note]) -> [(label: String, notes: [Note])] {
        var groups: [String: [Note]] = [:]
        var none: [Note] = []
        for n in notes {
            if let t = n.theme { groups[t, default: []].append(n) } else { none.append(n) }
        }
        var result = groups.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (label: $0.key, notes: $0.value) }
        if !none.isEmpty { result.append((label: "без темы", notes: none)) }
        return result
    }

    private static func snippets(_ body: String, words: [String]) -> [String] {
        var out: [String] = []
        for w in words {
            guard let r = body.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = body.index(r.lowerBound, offsetBy: -45, limitedBy: body.startIndex) ?? body.startIndex
            let end = body.index(r.upperBound, offsetBy: 45, limitedBy: body.endIndex) ?? body.endIndex
            let s = body[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let piece = (start > body.startIndex ? "…" : "") + s + (end < body.endIndex ? "…" : "")
            if !out.contains(where: { $0.contains(s) }) { out.append(piece) }
            if out.count >= 2 { break }
        }
        return out
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)).trimmingCharacters(in: .whitespaces) + "…" : s
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}

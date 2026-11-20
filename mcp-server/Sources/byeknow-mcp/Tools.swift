import Foundation

/// Инструменты MCP поверх папки с заметками.
struct Tools {
    let vault: Vault

    nonisolated(unsafe) static let definitions: [[String: Any]] = [
        [
            "name": "list_themes",
            "description": "Темы (папки) заметок ByeKnow и сколько в каждой заметок.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "list_notes",
            "description": "Список заметок ByeKnow (новые сверху): название, путь, тема, цвет, связи. Можно отфильтровать по теме.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "theme": ["type": "string", "description": "Только заметки этой темы. Пустая строка — заметки без темы."],
                    "limit": ["type": "integer", "description": "Сколько вернуть (по умолчанию 100)."],
                ],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "search_notes",
            "description": "Полнотекстовый поиск по заметкам ByeKnow (название и текст, без учёта регистра). Возвращает заметки с отрывками вокруг найденного.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Что искать. Несколько слов — должны встретиться все."],
                    "theme": ["type": "string", "description": "Искать только в этой теме."],
                    "limit": ["type": "integer", "description": "Сколько вернуть (по умолчанию 20)."],
                ],
                "required": ["query"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "read_note",
            "description": "Полный текст заметки ByeKnow в Markdown вместе с шапкой (тема, цвет, связи [[...]]). Заметку можно указать путём, названием, [[ссылкой]] или id.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "note": ["type": "string", "description": "Путь (например «Работа/План.md»), название, [[ссылка]] или id."],
                ],
                "required": ["note"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "create_note",
            "description": "Создать новую заметку в ByeKnow. Она появится на холсте в течение пары секунд, если приложение ByeKnow открыто (иначе — при следующем запуске). Существующие заметки этим инструментом не меняются.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Название заметки."],
                    "body": ["type": "string", "description": "Текст в Markdown. Каждая строка — отдельный блок: «## …» — заголовок, «- [ ] …» — пункт чек-листа, «---» — разделитель, строка-ссылка — ссылка."],
                    "theme": ["type": "string", "description": "Тема. Если такой нет — будет создана."],
                    "color": ["type": "string", "enum": Vault.colors, "description": "Цвет заметки."],
                    "links_to": ["type": "array", "items": ["type": "string"], "description": "Названия существующих заметок, к которым провести стрелки."],
                ],
                "required": ["title"],
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false],
        ],
    ]

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "list_themes": return try listThemes()
        case "list_notes": return try listNotes(theme: args["theme"] as? String, limit: Self.int(args["limit"]) ?? 100)
        case "search_notes":
            guard let q = args["query"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw VaultError.message("Нужен параметр query.")
            }
            return try search(q, theme: args["theme"] as? String, limit: Self.int(args["limit"]) ?? 20)
        case "read_note":
            guard let ref = args["note"] as? String else { throw VaultError.message("Нужен параметр note.") }
            let note = try vault.find(ref)
            return "path: \(note.path)\n\n" + note.raw
        case "create_note":
            let path = try vault.createNote(
                title: args["title"] as? String ?? "",
                body: args["body"] as? String ?? "",
                theme: args["theme"] as? String,
                color: args["color"] as? String,
                linksTo: (args["links_to"] as? [Any])?.compactMap { $0 as? String } ?? []
            )
            return "Заметка передана в ByeKnow (\(path)). Приложение добавит её на холст, когда оно открыто; после этого она появится в list_notes."
        default:
            throw VaultError.message("Неизвестный инструмент: \(name)")
        }
    }

    private func listThemes() throws -> String {
        let notes = try vault.notes()
        var counts: [String: Int] = [:]
        var none = 0
        for n in notes {
            if let t = n.theme { counts[t, default: 0] += 1 } else { none += 1 }
        }
        var list: [[String: Any]] = counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ["theme": $0.key, "notes": $0.value] }
        if none > 0 { list.append(["theme": "", "notes": none, "note": "без темы"]) }
        return Self.json(["total_notes": notes.count, "themes": list])
    }

    private func filtered(_ notes: [Note], theme: String?) -> [Note] {
        guard let theme else { return notes }
        let t = theme.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return notes.filter { $0.theme == nil } }
        return notes.filter { $0.theme?.compare(t, options: .caseInsensitive) == .orderedSame }
    }

    private func listNotes(theme: String?, limit: Int) throws -> String {
        let notes = filtered(try vault.notes(), theme: theme)
        return Self.json([
            "total": notes.count,
            "notes": notes.prefix(max(limit, 1)).map(\.summary),
        ])
    }

    private func search(_ query: String, theme: String?, limit: Int) throws -> String {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [(score: Int, note: Note)] = []
        for note in filtered(try vault.notes(), theme: theme) {
            let haystack = note.title + "\n" + note.body
            guard words.allSatisfy({ haystack.range(of: $0, options: opts) != nil }) else { continue }
            var score = 0
            for w in words {
                if note.title.range(of: w, options: opts) != nil { score += 10 }
                score += min(note.body.components(separatedBy: w).count - 1, 5)
            }
            hits.append((score, note))
        }
        hits.sort { $0.score > $1.score }
        let results: [[String: Any]] = hits.prefix(max(limit, 1)).map { hit in
            var d = hit.note.summary
            d["snippets"] = Self.snippets(hit.note.body, words: words)
            return d
        }
        return Self.json(["total": hits.count, "results": results])
    }

    private static func snippets(_ body: String, words: [String]) -> [String] {
        var out: [String] = []
        for w in words {
            guard let r = body.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = body.index(r.lowerBound, offsetBy: -80, limitedBy: body.startIndex) ?? body.startIndex
            let end = body.index(r.upperBound, offsetBy: 80, limitedBy: body.endIndex) ?? body.endIndex
            let s = body[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let piece = (start > body.startIndex ? "…" : "") + s + (end < body.endIndex ? "…" : "")
            if !out.contains(piece) { out.append(piece) }
            if out.count >= 3 { break }
        }
        return out
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func json(_ v: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

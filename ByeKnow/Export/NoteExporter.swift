#if os(macOS)
import AppKit
import Foundation
import SwiftData

/// Зеркало заметок в папке с Markdown — чтобы их могли читать ИИ-ассистенты (через MCP) или Obsidian.
///
/// По файлу `.md` на заметку, подпапки — темы. Связи-стрелки — `[[название]]` в шапке.
/// Файлы, которые кто-то положит в подпапку `inbox/`, становятся новыми заметками.
@Observable
final class NoteExporter {
    static let inboxName = "inbox"
    static let attachmentsName = "attachments"
    static let historyName = ".history"
    private static let manifestName = ".byeknow-export.json"
    private static let bookmarkKey = "export.bookmark"
    private static let enabledKey = "export.enabled"
    /// Ключи цветов в шапке файла — в том же порядке, что и `Palette.swatches`.
    static let colorKeys = ["default", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]

    let context: ModelContext

    private(set) var isEnabled: Bool
    private(set) var folderURL: URL?
    private(set) var lastExport: Date?
    private(set) var errorMessage: String?

    private var debounceTask: Task<Void, Never>?
    private var inboxTask: Task<Void, Never>?
    private var saveObserver: NSObjectProtocol?
    /// Что уже записано в файлы — чтобы не перезаписывать одинаковое.
    private var written: [String: String] = [:]
    /// Имя файла (без .md, в нижнем регистре) → заметка. Для `[[ссылок]]` из входящих.
    private var fileNames: [String: UUID] = [:]
    /// Заметка → путь её файла в папке. Для копий в `.history` перед изменением.
    private var filePaths: [UUID: String] = [:]

    init(context: ModelContext) {
        self.context = context
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        folderURL = Self.resolveBookmark()
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleExport() }
        }
        if isEnabled, folderURL != nil {
            start()
        } else if isEnabled {
            isEnabled = false
            errorMessage = tr("Нет доступа к папке — выбери её снова")
        }
    }

    // MARK: - Включение и папка

    /// Включить или выключить. Без папки сначала спрашивает её.
    func setEnabled(_ on: Bool) {
        if on, folderURL == nil {
            guard chooseFolder() else { return }
        }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        on ? start() : stop()
    }

    /// Окно выбора папки. Возвращает true, если папку выбрали.
    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Выбрать")
        panel.message = tr("Папка для заметок в Markdown")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        } catch {
            errorMessage = tr("Не удалось запомнить папку") + ": " + error.localizedDescription
            return false
        }
        folderURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        folderURL = url
        written = [:]
        if isEnabled { exportNow() }
        return true
    }

    func revealInFinder() {
        guard let folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    private static func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    private func start() {
        exportNow()
        inboxTask?.cancel()
        inboxTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.importInbox()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stop() {
        debounceTask?.cancel()
        inboxTask?.cancel()
        inboxTask = nil
    }

    /// После сохранения базы — обновить файлы через секунду (правки подряд склеиваются).
    private func scheduleExport() {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.exportNow()
        }
    }

    // MARK: - Экспорт

    func exportNow() {
        guard isEnabled, let root = folderURL else { return }
        do {
            try export(to: root)
            lastExport = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(to root: URL) throws {
        let fm = FileManager.default
        let nodes = try context.fetch(FetchDescriptor<Node>())
            .filter { $0.deletedAt == nil && !$0.isRoot }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let ids = Set(nodes.map(\.id))
        let connections = try context.fetch(FetchDescriptor<Connection>())
            .filter { ids.contains($0.fromID) && ids.contains($0.toID) && $0.fromID != $0.toID }

        // Имена файлов уникальны во всей папке — тогда `[[имя]]` всегда однозначно.
        var usedNames: Set<String> = []
        var names: [UUID: String] = [:]
        for node in nodes {
            let name = Self.unique(Self.sanitize(node.displayTitle), in: &usedNames)
            names[node.id] = name
        }
        fileNames = Dictionary(names.map { ($1.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        var usedFolders: Set<String> = [Self.inboxName, Self.attachmentsName]
        var folders: [UUID: String] = [:]
        let themes = try context.fetch(FetchDescriptor<Theme>()).sorted { ($0.order, $0.name) < ($1.order, $1.name) }
        for theme in themes {
            folders[theme.id] = Self.unique(Self.sanitize(theme.name.isEmpty ? tr("Тема") : theme.name), in: &usedFolders)
        }

        var outgoing: [UUID: [UUID]] = [:]
        var incoming: [UUID: [UUID]] = [:]
        for c in connections.sorted(by: { $0.createdAt < $1.createdAt }) {
            outgoing[c.fromID, default: []].append(c.toID)
            incoming[c.toID, default: []].append(c.fromID)
        }

        var files: [String: String] = [:]
        filePaths = [:]
        var attachments: [String: NoteBlock] = [:]
        for node in nodes {
            let folder = node.theme.flatMap { folders[$0.id] }
            let path = (folder.map { $0 + "/" } ?? "") + names[node.id]! + ".md"
            filePaths[node.id] = path
            files[path] = render(
                node,
                folderName: folder.map { _ in node.theme?.name ?? "" },
                links: (outgoing[node.id] ?? []).compactMap { names[$0] },
                backlinks: (incoming[node.id] ?? []).compactMap { names[$0] },
                attachmentPrefix: folder == nil ? "" : "../",
                attachments: &attachments
            )
        }

        // Записываем только то, что поменялось.
        for (path, text) in files {
            let url = root.appending(path: path)
            if written[path] == text { continue }
            if written[path] == nil, (try? String(contentsOf: url, encoding: .utf8)) == text {
                written[path] = text
                continue
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            written[path] = text
        }
        // Картинки называются по отпечатку — если файл есть, он уже такой, какой нужен.
        for (path, block) in attachments {
            let url = root.appending(path: path)
            guard !fm.fileExists(atPath: url.path(percentEncoded: false)), let data = block.imageData else { continue }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }

        // Убираем файлы удалённых и переименованных заметок — только те, что писали мы сами.
        let current = Set(files.keys).union(attachments.keys)
        let manifestURL = root.appending(path: Self.manifestName)
        let previous = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: manifestURL))) ?? []
        for path in previous where !current.contains(path) {
            let url = root.appending(path: path)
            try? fm.removeItem(at: url)
            written[path] = nil
            let parent = url.deletingLastPathComponent()
            if parent.standardizedFileURL != root.standardizedFileURL,
               (try? fm.contentsOfDirectory(atPath: parent.path(percentEncoded: false)))?.isEmpty == true {
                try? fm.removeItem(at: parent)
            }
        }
        try JSONEncoder().encode(current.sorted()).write(to: manifestURL, options: .atomic)
        try fm.createDirectory(at: root.appending(path: Self.inboxName), withIntermediateDirectories: true)
    }

    private func render(
        _ node: Node,
        folderName: String?,
        links: [String],
        backlinks: [String],
        attachmentPrefix: String,
        attachments: inout [String: NoteBlock]
    ) -> String {
        var head = ["---", "id: \(node.id.uuidString)", "title: \(Self.quote(node.displayTitle))"]
        if let folderName { head.append("theme: \(Self.quote(folderName))") }
        let colorIndex = Self.colorKeys.indices.contains(node.fillIndex) ? node.fillIndex : 0
        head.append("color: \(Self.colorKeys[colorIndex])")
        head.append("shape: \(node.shape.rawValue)")
        head.append("created: \(node.createdAt.formatted(.iso8601))")
        head.append("links_to: [\(links.map { Self.quote("[[\($0)]]") }.joined(separator: ", "))]")
        head.append("linked_from: [\(backlinks.map { Self.quote("[[\($0)]]") }.joined(separator: ", "))]")
        head.append("---")

        var parts: [String] = ["# " + node.displayTitle]
        var previousWasChecklist = false
        for block in node.sortedBlocks {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var line: String?
            switch block.kind {
            case .text: line = text.isEmpty ? nil : text
            case .heading: line = text.isEmpty ? nil : "## " + text
            case .checklist: line = text.isEmpty ? nil : (block.isChecked ? "- [x] " : "- [ ] ") + text
            case .divider: line = "---"
            case .link:
                if let url = block.url { line = "[\(text)](\(url.absoluteString))" } else if !text.isEmpty { line = text }
            case .image:
                if let hash = block.storedImageHash {
                    let path = Self.attachmentsName + "/" + hash + "." + Self.imageExtension(block)
                    attachments[path] = block
                    line = "![](\(attachmentPrefix)\(path))"
                }
            }
            guard let line else { continue }
            let isChecklist = block.kind == .checklist
            if isChecklist, previousWasChecklist {
                parts[parts.count - 1] += "\n" + line
            } else {
                parts.append(line)
            }
            previousWasChecklist = isChecklist
        }
        return head.joined(separator: "\n") + "\n\n" + parts.joined(separator: "\n\n") + "\n"
    }

    private static func imageExtension(_ block: NoteBlock) -> String {
        guard let data = block.imageData, data.count >= 12 else { return "img" }
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if Array(b[8...11]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if String(bytes: b[4...11], encoding: .ascii)?.hasPrefix("ftyphei") == true { return "heic" }
        return "img"
    }

    // MARK: - Входящие: новые заметки от ИИ

    /// Каждый `.md` в `inbox/` превращается в заметку, а файл удаляется.
    func importInbox() {
        guard isEnabled, let root = folderURL else { return }
        let fm = FileManager.default
        let inbox = root.appending(path: Self.inboxName, directoryHint: .isDirectory)
        guard let items = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        let files = items
            .filter { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return }

        var done: [URL] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            applyInboxFile(text, fallbackTitle: file.deletingPathExtension().lastPathComponent)
            done.append(file)
        }
        do {
            try context.save()
            for file in done { try? fm.removeItem(at: file) }
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    /// Файл из inbox. Заметка с таким названием уже есть — дополняем её, нет — создаём.
    ///
    /// Шапка: `title` (или `note`) — название; `mode` — `append` (дописать в конец, по умолчанию),
    /// `section` (заменить раздел `section`, нет такого — добавить), `replace` (заменить весь текст),
    /// `new` (всегда новая заметка); `theme`, `color`, `links_to` — как при создании.
    private func applyInboxFile(_ text: String, fallbackTitle: String) {
        let (meta, bodyLines) = Self.parseFrontMatter(text)
        var lines = bodyLines
        var title = ((meta["note"] ?? meta["title"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# ") {
            let heading = String(lines[first].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if title.isEmpty || title == heading {
                title = heading
                lines.remove(at: first)
            }
        }
        if title.isEmpty { title = fallbackTitle }

        let section = (meta["section"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let mode = (meta["mode"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces).nonEmpty
            ?? (section == nil ? "append" : "section")
        let all = (try? context.fetch(FetchDescriptor<Node>())) ?? []
        let alive = all.filter { $0.deletedAt == nil && !$0.isRoot }
        let items = Self.blocks(from: lines)

        let node: Node
        if mode != "new", let existing = findNode(title, in: alive) {
            node = existing
            backup(node)
            update(node, with: items, mode: mode, section: section)
        } else {
            let rootNode = all.first { $0.isRoot }
            let angle = Double.random(in: 0..<(2 * .pi))
            let radius = Double.random(in: 260...420)
            let center = rootNode?.position ?? .zero
            node = Node(position: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
            node.title = title
            node.shape = AppSettings.shared.defaultShape
            if node.shape == .sticker { node.fillIndex = 3 }
            context.insert(node)
            if let section { node.addBlock(.heading, context: context).text = section }
            append(items, to: node)
            if node.blocks.isEmpty { node.addBlock(.text, context: context) }
        }

        if let color = meta["color"] as? String, let index = Self.colorIndex(color) { node.fillIndex = index }
        if let themeName = (meta["theme"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !themeName.isEmpty {
            let themes = (try? context.fetch(FetchDescriptor<Theme>())) ?? []
            if let theme = themes.first(where: { $0.name.compare(themeName, options: .caseInsensitive) == .orderedSame }) {
                node.theme = theme
            } else {
                let theme = Theme(name: themeName, colorIndex: themes.count % 8 + 1, order: themes.count)
                context.insert(theme)
                node.theme = theme
            }
        }

        // Стрелки к другим заметкам — по названию или имени файла; уже проведённые не дублируем.
        let connections = (try? context.fetch(FetchDescriptor<Connection>())) ?? []
        var linked = Set(connections.flatMap { c -> [UUID] in
            c.fromID == node.id ? [c.toID] : c.toID == node.id ? [c.fromID] : []
        })
        for target in Self.stringList(meta["links_to"]) {
            guard let other = findNode(target, in: alive), other.id != node.id, !linked.contains(other.id) else { continue }
            linked.insert(other.id)
            context.insert(Connection(from: node.id, to: other.id))
        }
    }

    /// Заметка по id, имени файла в папке или названию (без учёта регистра).
    private func findNode(_ ref: String, in nodes: [Node]) -> Node? {
        let key = ref.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let id = UUID(uuidString: key), let n = nodes.first(where: { $0.id == id }) { return n }
        if let id = fileNames[key], let n = nodes.first(where: { $0.id == id }) { return n }
        return nodes.first { $0.displayTitle.lowercased() == key }
    }

    private func update(_ node: Node, with items: [(BlockKind, String, Bool)], mode: String, section: String?) {
        switch mode {
        case "replace":
            for b in node.sortedBlocks { node.remove(b, context: context) }
            append(items, to: node)
            if node.blocks.isEmpty { node.addBlock(.text, context: context) }
        case "section" where section != nil:
            let key = section!.lowercased()
            var items = items
            if let first = items.first, first.0 == .heading, first.1.lowercased() == key { items.removeFirst() }
            let list = node.sortedBlocks
            if let h = list.firstIndex(where: { $0.kind == .heading && $0.text.trimmingCharacters(in: .whitespaces).lowercased() == key }) {
                let end = list[(h + 1)...].firstIndex { $0.kind == .heading } ?? list.count
                for b in list[(h + 1)..<end] { node.remove(b, context: context) }
                var after = list[h]
                for (kind, text, checked) in items {
                    after = node.addBlock(kind, after: after, context: context)
                    after.text = text
                    after.isChecked = checked
                }
            } else {
                dropPlaceholder(node)
                node.addBlock(.heading, context: context).text = section!
                append(items, to: node)
            }
        default:
            dropPlaceholder(node)
            append(items, to: node)
        }
    }

    private func append(_ items: [(BlockKind, String, Bool)], to node: Node) {
        for (kind, text, checked) in items {
            let block = node.addBlock(kind, context: context)
            block.text = text
            block.isChecked = checked
        }
    }

    /// Единственная пустая строка новой заметки мешает дописывать — убираем её.
    private func dropPlaceholder(_ node: Node) {
        let list = node.sortedBlocks
        if list.count == 1, list[0].kind == .text, list[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            node.remove(list[0], context: context)
        }
    }

    /// Копия файла заметки до изменения — в скрытой папке `.history`.
    private func backup(_ node: Node) {
        guard let root = folderURL, let path = filePaths[node.id] else { return }
        let fm = FileManager.default
        let source = root.appending(path: path)
        guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        let dir = root.appending(path: Self.historyName, directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let name = source.deletingPathExtension().lastPathComponent + " " + stamp + ".md"
        try? fm.copyItem(at: source, to: dir.appending(path: name))
    }

    private static func blocks(from lines: [String]) -> [(BlockKind, String, Bool)] {
        var result: [(BlockKind, String, Bool)] = []
        var inCode = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { result.append((.text, raw, false)); continue }
            if line.isEmpty { continue }
            if ["---", "***", "___"].contains(line) {
                result.append((.divider, "", false))
            } else if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                result.append((.heading, String(line[range.upperBound...]), false))
            } else if let range = line.range(of: #"^[-*+]\s+\[( |x|X)\]\s*"#, options: .regularExpression) {
                let checked = line[range].lowercased().contains("[x]")
                result.append((.checklist, String(line[range.upperBound...]), checked))
            } else if let url = linkURL(line) {
                result.append((.link, url, false))
            } else if let range = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                result.append((.text, "• " + line[range.upperBound...], false))
            } else {
                result.append((.text, line, false))
            }
        }
        return result
    }

    /// Строка — это только ссылка: `https://…`, `<https://…>` или `[текст](https://…)`.
    private static func linkURL(_ line: String) -> String? {
        var s = line
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        if let m = s.wholeMatch(of: /\[[^\]]*\]\((\S+)\)/) { s = String(m.1) }
        guard !s.contains(" "), s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        return s
    }

    // MARK: - Разбор шапки

    /// YAML-шапка между `---`. Значения — строки или списки (в том числе в виде JSON).
    static func parseFrontMatter(_ text: String) -> ([String: Any], [String]) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], lines)
        }
        var meta: [String: Any] = [:]
        var listKey: String?
        for line in lines[1..<end] {
            // Список в виде строк «- значение» под ключом.
            if let key = listKey, let m = line.wholeMatch(of: /\s*-\s+(.*)/) {
                var list = meta[key] as? [String] ?? []
                list.append(unquote(String(m.1)))
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
            } else if value.hasPrefix("["),
                      let data = value.data(using: .utf8),
                      let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                meta[key] = list.map { "\($0)" }
            } else if value.hasPrefix("[") {
                meta[key] = value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }
            } else {
                meta[key] = unquote(value)
            }
        }
        return (meta, Array(lines[(end + 1)...]))
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), let data = t.data(using: .utf8),
           let v = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            return v
        }
        if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") { return String(t.dropFirst().dropLast()) }
        return t
    }

    private static func stringList(_ value: Any?) -> [String] {
        let list = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
        return list.map {
            var s = $0.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("[["), s.hasSuffix("]]") { s = String(s.dropFirst(2).dropLast(2)) }
            if let bar = s.firstIndex(of: "|") { s = String(s[..<bar]) }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private static func colorIndex(_ value: String) -> Int? {
        let v = value.lowercased().trimmingCharacters(in: .whitespaces)
        if let i = colorKeys.firstIndex(of: v) { return i }
        return Palette.swatches.firstIndex { $0.name.lowercased() == v }
    }

    // MARK: - Имена

    static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Имя файла или папки: без запрещённых знаков и не слишком длинное.
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]\n\r\t")
        var s = name.components(separatedBy: bad).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 100 { s = String(s.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? tr("Новая заметка") : s
    }

    private static func unique(_ base: String, in used: inout Set<String>) -> String {
        var name = base
        var i = 2
        while used.contains(name.lowercased()) {
            name = "\(base) (\(i))"
            i += 1
        }
        used.insert(name.lowercased())
        return name
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif

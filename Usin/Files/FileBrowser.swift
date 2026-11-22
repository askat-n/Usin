import SwiftUI
import SwiftData

/// Заметки, разложенные по темам — как файлы по папкам.
struct NoteFolder: Identifiable {
    let id: UUID?          // nil — «Без темы»
    let name: String
    let color: Color
    let notes: [Node]
    /// Свой значок вместо папки (у «Памяти ИИ»).
    var symbol: String? = nil
}

private let noThemeFolderID = UUID(uuidString: "00000000-0000-4000-8000-00000000F01D")!
private let memoryFolderID = UUID(uuidString: "00000000-0000-4000-8000-0000000A1A1A")!

/// «Память ИИ» — не тема, а все заметки с отметкой «Для ИИ» из любых тем: то, что видят ИИ-ассистенты.
func memoryFolder(nodes: [Node]) -> NoteFolder {
    let notes = nodes.filter { !$0.isRoot && $0.isForAI }
        .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    return NoteFolder(id: memoryFolderID, name: L("Память ИИ"), color: AIAccess.color, notes: notes, symbol: AIAccess.symbol)
}

/// Папки-темы по порядку, в конце — «Без темы». Заметки внутри — по названию.
func noteFolders(nodes: [Node], themes: [Theme]) -> [NoteFolder] {
    let notes = nodes.filter { !$0.isRoot }
    func sorted(_ list: [Node]) -> [Node] {
        list.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }
    var folders = themes.sorted { $0.order < $1.order }.map { theme in
        NoteFolder(id: theme.id, name: theme.name,
                   color: Palette.swatch(theme.colorIndex).ink,
                   notes: sorted(notes.filter { $0.theme?.id == theme.id }))
    }
    let loose = notes.filter { $0.theme == nil }
    if !loose.isEmpty || folders.isEmpty {
        folders.append(NoteFolder(id: nil, name: L("Без темы"), color: .secondary, notes: sorted(loose)))
    }
    return folders
}

// MARK: - Sidebar (проводник слева)

struct FileSidebar: View {
    @Environment(Workspace.self) private var ws
    @Query(filter: #Predicate<Node> { $0.deletedAt == nil }) private var nodes: [Node]
    @Query(sort: \Theme.order) private var themes: [Theme]
    /// Свёрнутые папки (по умолчанию все раскрыты).
    @State private var collapsed: Set<UUID> = []
    var onOpen: () -> Void = {}

    var body: some View {
        let folders = noteFolders(nodes: nodes, themes: themes)
        let memory = memoryFolder(nodes: nodes)
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(L("Заметки").uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                FilesModeButton(active: ws.activeTab == nil && ws.home == .files) {
                    ws.showHome(ws.activeTab == nil && ws.home == .files ? .canvas : .files)
                    onOpen()
                }
                .padding(.leading, 6)
                Spacer()
                SidebarIconButton(icon: "plus", help: L("Новая заметка во вкладке (⌘T)")) {
                    ws.newNoteTab()
                    onOpen()
                }
                SidebarIconButton(icon: "rectangle.compress.vertical", help: L("Свернуть все")) {
                    withAnimation(.snappy(duration: 0.2)) {
                        collapsed = Set(folders.map { $0.id ?? noThemeFolderID } + [memoryFolderID])
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 36)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let memoryOpen = !collapsed.contains(memoryFolderID)
                    FolderRow(folder: memory, open: memoryOpen) {
                        withAnimation(.snappy(duration: 0.2)) {
                            if memoryOpen { collapsed.insert(memoryFolderID) } else { collapsed.remove(memoryFolderID) }
                        }
                    }
                    if memoryOpen {
                        if memory.notes.isEmpty {
                            Text(L("Здесь то, что видят ИИ-ассистенты. Отметь заметку «Для ИИ» — она появится здесь."))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 34)
                                .padding(.trailing, 12)
                                .padding(.vertical, 4)
                        }
                        ForEach(memory.notes) { note in
                            NoteFileRow(note: note, active: ws.activeTab == note.id, showsAIMark: false) {
                                ws.open(note)
                                onOpen()
                            }
                        }
                    }
                    Divider().padding(.vertical, 4).padding(.horizontal, 12)
                    ForEach(folders) { folder in
                        let key = folder.id ?? noThemeFolderID
                        let open = !collapsed.contains(key)
                        FolderRow(folder: folder, open: open) {
                            withAnimation(.snappy(duration: 0.2)) {
                                if open { collapsed.insert(key) } else { collapsed.remove(key) }
                            }
                        }
                        if open {
                            ForEach(folder.notes) { note in
                                NoteFileRow(note: note, active: ws.activeTab == note.id) {
                                    ws.open(note)
                                    onOpen()
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// «Файлы» — заметки плиткой вместо холста. Нажать ещё раз — обратно к холсту.
private struct FilesModeButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: active ? "folder.fill" : "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text(L("Файлы"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(active ? Color.accentColor.opacity(0.15) : Color.primary.opacity(hovering ? 0.08 : 0.04),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Заметки как файлы"))
    }
}

private struct SidebarIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct FolderRow: View {
    let folder: NoteFolder
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 12)
            Image(systemName: folder.symbol ?? (open ? "folder.fill" : "folder"))
                .font(.system(size: 13))
                .foregroundStyle(folder.color)
            Text(folder.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(folder.notes.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 28)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
    }
}

private struct NoteFileRow: View {
    let note: Node
    let active: Bool
    var showsAIMark = true
    let open: () -> Void
    @Environment(Workspace.self) private var ws
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(active ? Color.accentColor : .secondary)
            Text(note.displayTitle)
                .font(.system(size: 13))
                .opacity(note.hasTitle ? 1 : 0.5)
                .lineLimit(1)
            Spacer(minLength: 0)
            if showsAIMark && note.isForAI {
                Image(systemName: AIAccess.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AIAccess.color)
                    .help(L("Видна ИИ"))
            }
        }
        .padding(.leading, 34)
        .padding(.trailing, 12)
        .frame(height: 26)
        .background(active ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.05) : .clear))
        .overlay(alignment: .leading) {
            if active { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu { NoteFileMenu(note: note) }
    }
}

private struct NoteFileMenu: View {
    let note: Node
    @Environment(Workspace.self) private var ws

    var body: some View {
        Button { ws.open(note) } label: { Label(L("Открыть во вкладке"), systemImage: "macwindow") }
        Button { ws.showOnCanvas(note) } label: { Label(L("Показать на холсте"), systemImage: "circle.hexagongrid") }
        AIAccessMenuItem(node: note)
        Divider()
        Button(role: .destructive) { ws.delete(note) } label: {
            Label(L("Переместить в корзину"), systemImage: "trash")
        }
    }
}

// MARK: - «Файлы»: заметки не на холсте, а плиткой по папкам

struct FilesView: View {
    @Environment(Workspace.self) private var ws
    @Query(filter: #Predicate<Node> { $0.deletedAt == nil }) private var nodes: [Node]
    @Query(sort: \Theme.order) private var themes: [Theme]

    var body: some View {
        let memory = memoryFolder(nodes: nodes)
        let folders = (memory.notes.isEmpty ? [] : [memory]) + noteFolders(nodes: nodes, themes: themes)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(folders) { folder in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: folder.symbol ?? "folder.fill").foregroundStyle(folder.color)
                            Text(folder.name).font(.headline)
                            Text("\(folder.notes.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if folder.notes.isEmpty {
                            Text(L("Пока нет заметок"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)],
                                      alignment: .leading, spacing: 14) {
                                ForEach(folder.notes) { note in
                                    FileTile(note: note, tint: folder.color)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FileTile: View {
    let note: Node
    let tint: Color
    @Environment(Workspace.self) private var ws
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 26))
                .foregroundStyle(tint.opacity(0.85))
            Text(note.displayTitle)
                .font(.subheadline.weight(.semibold))
                .opacity(note.hasTitle ? 1 : 0.5)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(note.preview.isEmpty ? " " : note.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(note.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.primary.opacity(hovering ? 0.08 : 0.045),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(ws.openTabs.contains(note.id) ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { ws.open(note) }
        .onHover { hovering = $0 }
        .contextMenu { NoteFileMenu(note: note) }
    }
}

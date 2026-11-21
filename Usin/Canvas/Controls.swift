import SwiftUI
import SwiftData

// MARK: - Basic pieces

struct ToolButton: View {
    let icon: String
    var active = false
    var help = ""
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(destructive ? Color.red : (active ? Color.accentColor : Color.primary))
                .frame(width: 34, height: 34)
                .background(active ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct BarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 3)
    }
}

struct FloatingBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(5)
            .panelBackground()
    }
}

// MARK: - Colors

struct ColorGrid: View {
    @Binding var selection: Int
    var useInk: Bool

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 10), count: 3), spacing: 10) {
            ForEach(Palette.swatches.indices, id: \.self) { i in
                let swatch = Palette.swatches[i]
                // В «Терминале» показываем яркий цвет — тот, что увидишь на заметке.
                let showInk = useInk || AppSettings.shared.isTerminal
                Button { selection = i } label: {
                    Circle()
                        .fill(showInk ? swatch.ink : swatch.fill)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15)))
                        .overlay {
                            if selection == i {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(showInk ? Color.black : Color.primary)
                            }
                        }
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(tr(swatch.name))
            }
        }
        .padding(14)
    }
}

struct ColorButton: View {
    @Binding var index: Int
    /// true — показывать насыщенные цвета (текст, стрелки, сфера).
    var useInk: Bool
    var textIcon = false
    var help = ""

    @State private var shown = false

    var body: some View {
        let swatch = Palette.swatch(index)
        Button { shown = true } label: {
            Group {
                if textIcon {
                    Image(systemName: "textformat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(swatch.ink)
                } else {
                    Circle()
                        .fill(useInk || AppSettings.shared.isTerminal ? swatch.ink : swatch.fill)
                        .overlay(Circle().stroke(Color.primary.opacity(0.2)))
                        .frame(width: 20, height: 20)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $shown) {
            ColorGrid(selection: $index, useInk: useInk)
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Themes

struct ThemeMenu: View {
    enum Style { case icon, chip }

    @Binding var theme: Theme?
    var style: Style = .icon

    @Environment(Workspace.self) private var ws
    @Query(sort: \Theme.order) private var themes: [Theme]
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        Menu {
            Button { theme = nil } label: {
                if theme == nil { Label(tr("Без темы"), systemImage: "checkmark") } else { Text(tr("Без темы")) }
            }
            ForEach(themes) { t in
                Button { theme = t } label: {
                    if theme?.id == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                }
            }
            Divider()
            Button(tr("Новая тема…"), systemImage: "plus") { creating = true }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("Тема"))
        .alert(tr("Новая тема"), isPresented: $creating) {
            TextField(tr("Название"), text: $newName)
            Button(tr("Создать")) {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { theme = ws.createTheme(named: name) }
                newName = ""
            }
            Button(tr("Отмена"), role: .cancel) { newName = "" }
        }
    }

    @ViewBuilder
    private var label: some View {
        let color = theme.map { Palette.swatch($0.colorIndex).ink } ?? Color.secondary
        switch style {
        case .icon:
            Image(systemName: theme == nil ? "tag" : "tag.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme == nil ? Color.primary : color)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        case .chip:
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(theme?.name ?? tr("Без темы"))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }
}

struct FilterBar: View {
    @Environment(Workspace.self) private var ws
    @Query(sort: \Theme.order) private var themes: [Theme]

    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: Theme?
    @State private var renameText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip(tr("Все"), color: .secondary, active: ws.filterThemeID == nil) {
                    ws.filterThemeID = nil
                }
                // Не тема, а отметка: заметки, которые видят ИИ-ассистенты.
                Button {
                    withAnimation(.snappy) { ws.filterThemeID = ws.isAIFilter ? nil : Workspace.aiFilterID }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: AIAccess.symbol).font(.system(size: 11, weight: .semibold))
                        Text(tr("Для ИИ")).lineLimit(1)
                    }
                    .font(.subheadline.weight(ws.isAIFilter ? .semibold : .regular))
                    .foregroundStyle(ws.isAIFilter ? AIAccess.color : Color.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(ws.isAIFilter ? AIAccess.color.opacity(0.18) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tr("Заметки, которые видят ИИ-ассистенты"))
                ForEach(themes) { t in
                    let active = ws.filterThemeID == t.id
                    chip(t.name, color: Palette.swatch(t.colorIndex).ink, active: active) {
                        withAnimation(.snappy) { ws.filterThemeID = active ? nil : t.id }
                    }
                    .contextMenu {
                        Button(tr("Переименовать"), systemImage: "pencil") {
                            renameText = t.name
                            renaming = t
                        }
                        Menu(tr("Цвет")) {
                            ForEach(1..<Palette.swatches.count, id: \.self) { i in
                                Button(tr(Palette.swatches[i].name)) { t.colorIndex = i }
                            }
                        }
                        Divider()
                        Button(tr("Удалить тему"), systemImage: "trash", role: .destructive) { ws.delete(t) }
                    }
                }
                Button { creating = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("Новая тема"))
            }
            .padding(4)
            .panelBackground()
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .alert(tr("Новая тема"), isPresented: $creating) {
            TextField(tr("Название"), text: $newName)
            Button(tr("Создать")) {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { ws.createTheme(named: name) }
                newName = ""
            }
            Button(tr("Отмена"), role: .cancel) { newName = "" }
        }
        .alert(tr("Переименовать тему"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(tr("Название"), text: $renameText)
            Button(tr("Готово")) {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { renaming?.name = name }
                renaming = nil
            }
            Button(tr("Отмена"), role: .cancel) { renaming = nil }
        }
    }

    private func chip(_ title: String, color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(active ? .semibold : .regular))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(active ? color.opacity(0.18) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Zoom

struct ZoomControls: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        VStack(spacing: 2) {
            ToolButton(icon: "plus", help: tr("Приблизить")) { withAnimation(.snappy) { ws.zoom(by: 1.25) } }
            Button { withAnimation(.snappy) { ws.resetZoom() } } label: {
                Text("\(Int((ws.scale * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("100%")
            ToolButton(icon: "minus", help: tr("Отдалить")) { withAnimation(.snappy) { ws.zoom(by: 0.8) } }
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 20, height: 1).padding(.vertical, 3)
            ToolButton(icon: "scope", help: tr("К сфере Usin")) { ws.goHome() }
        }
        .padding(5)
        .panelBackground()
    }
}

// MARK: - Inspectors

struct NodeInspector: View {
    @Bindable var node: Node
    @Environment(Workspace.self) private var ws

    var body: some View {
        FloatingBar {
            if !node.isRoot {
                ForEach(NodeShape.allCases) { shape in
                    ToolButton(icon: shape.icon, active: node.shape == shape, help: shape.title) {
                        node.shape = shape
                        if shape == .sticker && node.fillIndex == 0 { node.fillIndex = 3 }
                    }
                }
                BarSeparator()
            }
            ColorButton(index: $node.fillIndex, useInk: node.isRoot, help: tr("Цвет фигуры"))
            ColorButton(index: $node.inkIndex, useInk: true, textIcon: true, help: tr("Цвет текста"))
            if !node.isRoot {
                ThemeMenu(theme: $node.theme)
                ToolButton(icon: AIAccess.symbol, active: node.isForAI,
                           help: node.isForAI ? tr("Видна ИИ — нажми, чтобы скрыть") : tr("Открыть для ИИ")) {
                    node.isForAI.toggle()
                }
            }
            BarSeparator()
            ToolButton(icon: "pencil", help: tr("Переименовать")) { ws.startRenaming(node) }
            if !node.isRoot {
                ToolButton(icon: "arrow.up.forward.square", help: tr("Открыть во вкладке")) { ws.open(node) }
                ToolButton(icon: "trash", help: tr("Удалить"), destructive: true) { ws.delete(node) }
            }
        }
    }
}

struct ConnectionInspector: View {
    @Bindable var connection: Connection
    @Environment(Workspace.self) private var ws

    var body: some View {
        FloatingBar {
            ForEach(EdgeStyle.allCases) { style in
                ToolButton(icon: style.icon, active: connection.style == style, help: style.title) {
                    connection.style = style
                    if style == .straight {
                        connection.bendX = 0
                        connection.bendY = 0
                    } else if connection.bendX == 0 && connection.bendY == 0 {
                        connection.bendY = -50
                    }
                }
            }
            BarSeparator()
            ForEach(EdgeHead.allCases) { head in
                ToolButton(icon: head.icon, active: connection.head == head, help: head.title) {
                    connection.head = head
                }
            }
            BarSeparator()
            ToolButton(icon: "line.3.horizontal", active: connection.dashed, help: tr("Пунктир")) {
                connection.dashed.toggle()
            }
            ColorButton(index: $connection.colorIndex, useInk: true, help: tr("Цвет стрелки"))
            ToolButton(icon: "arrow.left.arrow.right", help: tr("Развернуть")) {
                let from = connection.fromID
                connection.fromID = connection.toID
                connection.toID = from
            }
            BarSeparator()
            ToolButton(icon: "trash", help: tr("Удалить"), destructive: true) { ws.deleteSelection() }
        }
    }
}

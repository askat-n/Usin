import SwiftUI
import SwiftData

struct ContentView: View {
    private var appBackground: Color {
        switch AppSettings.shared.canvasStyle {
        case .cosmos: Cosmos.deep
        case .terminal: Term.bg
        case .classic: Color.canvas
        }
    }

    @Environment(Workspace.self) private var ws
    @Environment(SyncEngine.self) private var sync
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.undoManager) private var undoManager
    @Query(filter: #Predicate<Node> { $0.deletedAt == nil }) private var nodes: [Node]
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        @Bindable var ws = ws
        VStack(spacing: 0) {
            TabBar()
            Divider()
            HStack(spacing: 0) {
                if ws.showSidebar && !compact {
                    FileSidebar()
                        .frame(width: 250)
                        .background(Color.primary.opacity(0.025))
                        .transition(.move(edge: .leading))
                    Divider()
                }
                Group {
                    if let id = ws.activeTab, let node = nodes.first(where: { $0.id == id }) {
                        NoteEditorView(node: node)
                            .id(id)
                    } else if ws.home == .files {
                        FilesView()
                    } else {
                        CanvasView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // iPhone: панель выезжает поверх, тап мимо — закрывает.
            .overlay(alignment: .leading) {
                if ws.showSidebar && compact {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.25)
                            .ignoresSafeArea()
                            .onTapGesture { withAnimation(.snappy) { ws.showSidebar = false } }
                            .transition(.opacity)
                        FileSidebar(onOpen: { withAnimation(.snappy) { ws.showSidebar = false } })
                            .frame(width: 280)
                            .background(appBackground.ignoresSafeArea())
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).ignoresSafeArea()
                            }
                            .transition(.move(edge: .leading))
                    }
                }
            }
        }
        // Под холстом (у полоски «домой» на iPhone) — тот же фон, без чёрной или белой полосы.
        .background(appBackground.ignoresSafeArea())
        // «Терминал»: моноширинный шрифт и зелёный акцент во всём приложении.
        .fontDesign(AppSettings.shared.isTerminal ? .monospaced : nil)
        .tint(AppSettings.shared.isTerminal ? Term.green : nil)
        .sheet(isPresented: $ws.showAllNotes) {
            AllNotesView()
        }
        #if os(macOS)
        // Значку в строке меню нужно уметь открыть окно холста, даже если все окна закрыты.
        .onAppear { StatusItemController.shared.openMainWindow = { openWindow(id: MainWindow.id) } }
        // На Mac настройки — отдельное окно (⌘,), как у обычных приложений.
        .onChange(of: ws.showSettings) { _, show in
            guard show else { return }
            ws.showSettings = false
            NSApp.activate()
            openSettings()
        }
        #else
        .sheet(isPresented: $ws.showSettings) {
            SettingsView()
        }
        #endif
        // Синхронизация: при запуске, при возвращении в приложение, после правок и проверка Drive каждую секунду.
        .task {
            await sync.syncNow()
            sync.startPeriodic()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await sync.syncNow() }
                sync.startPeriodic()
            } else {
                sync.stopPeriodic()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            sync.scheduleSync()
        }
        // ⌘Z / ⇧⌘Z: правки заметок и холста отменяются через стандартное «Правка → Отменить».
        .onAppear { ws.context.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in ws.context.undoManager = manager }
        // Возврат из браузера после входа в Google — в это же окно, не в новое.
        .onOpenURL { url in sync.handleRedirect(url) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}

// MARK: - Tabs

struct TabBar: View {
    @Environment(Workspace.self) private var ws
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif
    @Query(filter: #Predicate<Node> { $0.deletedAt == nil }) private var nodes: [Node]

    var body: some View {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        HStack(spacing: 6) {
            ToolButton(icon: "sidebar.left", active: ws.showSidebar,
                       help: tr("Показать или скрыть боковую панель (⌃⌘S)")) {
                withAnimation(.snappy) { ws.showSidebar.toggle() }
            }
            TabChip(title: compact ? "" : tr("Холст"), icon: "circle.hexagongrid", active: ws.activeTab == nil && ws.home == .canvas) {
                ws.showHome(.canvas)
            }
            if !ws.openTabs.isEmpty {
                BarSeparator()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ws.openTabs, id: \.self) { id in
                        if let node = byID[id] {
                            TabChip(
                                title: node.displayTitle,
                                color: node.theme.map { Palette.swatch($0.colorIndex).ink },
                                active: ws.activeTab == id,
                                onSelect: { ws.activeTab = id },
                                onClose: { ws.close(tab: id) }
                            )
                        }
                    }
                }
            }
            SyncIndicator()
            ToolButton(icon: "plus", help: tr("Новая заметка во вкладке (⌘T)")) { ws.newNoteTab() }
            ToolButton(icon: "magnifyingglass", help: tr("Все заметки (⌘K)")) { ws.showAllNotes = true }
            ToolButton(icon: "gearshape", help: tr("Настройки")) { ws.showSettings = true }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct TabChip: View {
    let title: String
    var icon: String? = nil
    var color: Color? = nil
    let active: Bool
    let onSelect: () -> Void
    var onClose: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            } else {
                Circle().fill(color ?? Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            }
            if !title.isEmpty {
                Text(title).lineLimit(1)
            }
            if let onClose, active || hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("Закрыть вкладку"))
            }
        }
        .font(.subheadline.weight(active ? .semibold : .regular))
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: 220)
        .fixedSize()
        .background(active ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - All notes / search

struct AllNotesView: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Node> { $0.deletedAt == nil }, sort: \Node.createdAt, order: .reverse)
    private var nodes: [Node]
    @State private var query = ""

    private var results: [Node] {
        nodes.filter { node in
            guard !node.isRoot else { return false }
            guard !query.isEmpty else { return true }
            return node.title.localizedCaseInsensitiveContains(query)
                || node.blocks.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { node in
                Button {
                    ws.open(node)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(node.theme.map { Palette.swatch($0.colorIndex).ink } ?? Color.secondary.opacity(0.3))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.displayTitle).font(.body.weight(.medium))
                            if !node.preview.isEmpty {
                                Text(node.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let theme = node.theme {
                            Text(theme.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if results.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView(tr("Пока нет заметок"), systemImage: "note.text",
                                               description: Text(tr("Удержи палец на пустом месте холста, чтобы создать первую")))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, prompt: tr("Поиск по заметкам"))
            .navigationTitle(tr("Все заметки"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Готово")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}

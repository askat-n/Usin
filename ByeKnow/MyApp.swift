import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

@main struct MyApp: App {
    let container: ModelContainer
    @State private var workspace: Workspace
    @State private var sync: SyncEngine

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Node.self, NoteBlock.self, Connection.self, Theme.self)
        } catch {
            fatalError("Не удалось открыть базу заметок: \(error)")
        }
        self.container = container
        _workspace = State(initialValue: Workspace(context: container.mainContext))
        _sync = State(initialValue: SyncEngine(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
                .environment(sync)
                .environment(AppSettings.shared)
                .preferredColorScheme(AppSettings.shared.effectiveColorScheme)
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        .commands {
            WorkspaceCommands(ws: workspace)
        }
    }
}

struct WorkspaceCommands: Commands {
    let ws: Workspace

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(tr("Настройки") + "…") { ws.showSettings = true }
                .keyboardShortcut(",")
        }

        // Файл
        CommandGroup(replacing: .newItem) {
            Button(tr("Новая заметка")) { ws.createNodeAtViewCenter() }
                .keyboardShortcut("n")
            Button(tr("Новая заметка во вкладке")) { ws.newNoteTab() }
                .keyboardShortcut("t")
            Button(tr("Открыть выбранную заметку")) { ws.openSelection() }
                .keyboardShortcut(.return, modifiers: .command)
            Button(tr("Дублировать")) { ws.duplicateSelection() }
                .keyboardShortcut("d")
        }
        CommandGroup(replacing: .saveItem) {
            // ⌘W — как в браузере: закрывает вкладку, а на холсте — окно.
            Button(tr("Закрыть вкладку")) { closeTabOrWindow() }
                .keyboardShortcut("w")
            Button(tr("Вернуть закрытую вкладку")) { ws.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        // Правка (⌘Z / ⇧⌘Z / ⌘X / ⌘C / ⌘V / ⌘A — системные)
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(tr("Переместить в корзину")) { ws.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button(tr("Найти…")) { ws.showAllNotes = true }
                .keyboardShortcut("f")
        }

        CommandMenu(tr("Холст")) {
            Button(tr("Все заметки…")) { ws.showAllNotes = true }
                .keyboardShortcut("k")
            Divider()
            Button(tr("К сфере ByeKnow")) { ws.showHome(.canvas); ws.goHome() }
                .keyboardShortcut("0")
            Button(tr("Приблизить")) { withAnimation(.snappy) { ws.zoom(by: 1.25) } }
                .keyboardShortcut("=")
            Button(tr("Отдалить")) { withAnimation(.snappy) { ws.zoom(by: 0.8) } }
                .keyboardShortcut("-")
        }

        CommandGroup(before: .toolbar) {
            Button(tr("Боковая панель")) { withAnimation(.snappy) { ws.showSidebar.toggle() } }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(tr("Файлы")) { ws.showHome(.files) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu(tr("Вкладки")) {
            Button(tr("Холст")) { ws.selectTab(at: 0) }
                .keyboardShortcut("1")
            ForEach(2..<10) { i in
                Button(tr("Вкладка") + " \(i - 1)") { ws.selectTab(at: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")))
            }
            Divider()
            Button(tr("Следующая вкладка")) { ws.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button(tr("Предыдущая вкладка")) { ws.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }

    private func closeTabOrWindow() {
        if let id = ws.activeTab {
            ws.close(tab: id)
        } else {
            #if os(macOS)
            NSApp.keyWindow?.performClose(nil)
            #endif
        }
    }
}

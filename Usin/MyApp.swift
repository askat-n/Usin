import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

@main struct MyApp: App {
    let container: ModelContainer
    @State private var workspace: Workspace
    @State private var sync: SyncEngine
    #if os(macOS)
    @State private var exporter: NoteExporter
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        let container: ModelContainer
        do {
            // На Mac приложение без песочницы: своя папка, иначе база легла бы в общую Application Support.
            let folder = URL.applicationSupportDirectory.appending(path: "Usin", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let config = ModelConfiguration(url: folder.appending(path: "Usin.store"))
            container = try ModelContainer(for: Node.self, NoteBlock.self, Connection.self, Theme.self,
                                           configurations: config)
        } catch {
            fatalError("Не удалось открыть базу заметок: \(error)")
        }
        self.container = container
        let workspace = Workspace(context: container.mainContext)
        _workspace = State(initialValue: workspace)
        _sync = State(initialValue: SyncEngine(context: container.mainContext))
        #if os(macOS)
        _exporter = State(initialValue: NoteExporter(context: container.mainContext))
        Updater.shared.beforeRelaunch = { try? container.mainContext.save() }
        Updater.shared.start()
        StatusItemController.shared.workspace = workspace
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(workspace)
                .environment(sync)
                #if os(macOS)
                .environment(exporter)
                #endif
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

        #if os(macOS)
        // Настройки — отдельное окно с боковой панелью (⌘,).
        Settings {
            SettingsView()
                .environment(workspace)
                .environment(sync)
                .environment(exporter)
                .environment(AppSettings.shared)
                .preferredColorScheme(AppSettings.shared.effectiveColorScheme)
        }
        .modelContainer(container)
        .windowResizability(.contentMinSize)

        #endif
    }
}

struct WorkspaceCommands: Commands {
    let ws: Workspace

    var body: some Commands {
        #if os(macOS)
        CommandGroup(after: .appInfo) {
            Button(tr("Проверить обновления") + "…") {
                Task { await Updater.shared.check(manual: true) }
            }
        }
        #endif
        #if os(iOS)
        // На Mac пункт «Настройки…» (⌘,) добавляет сцена Settings.
        CommandGroup(replacing: .appSettings) {
            Button(tr("Настройки") + "…") { ws.showSettings = true }
                .keyboardShortcut(",")
        }
        #endif

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
            Button(tr("К сфере Usin")) { ws.showHome(.canvas); ws.goHome() }
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

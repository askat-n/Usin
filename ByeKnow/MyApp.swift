import SwiftUI
import SwiftData

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
                .preferredColorScheme(AppSettings.shared.appearance.colorScheme)
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
        CommandGroup(replacing: .newItem) {
            Button(tr("Новая заметка")) { ws.createNodeAtViewCenter() }
                .keyboardShortcut("n")
            Button(tr("Новая заметка во вкладке")) { ws.newNoteTab() }
                .keyboardShortcut("t")
        }
        CommandMenu(tr("Холст")) {
            Button(tr("Все заметки…")) { ws.showAllNotes = true }
                .keyboardShortcut("k")
            Button(tr("К сфере ByeKnow")) { ws.activeTab = nil; ws.goHome() }
                .keyboardShortcut("0")
            Button(tr("Приблизить")) { withAnimation(.snappy) { ws.zoom(by: 1.25) } }
                .keyboardShortcut("=")
            Button(tr("Отдалить")) { withAnimation(.snappy) { ws.zoom(by: 0.8) } }
                .keyboardShortcut("-")
            Button(tr("Удалить выбранное")) { ws.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
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
            Button(tr("Закрыть вкладку")) { if let id = ws.activeTab { ws.close(tab: id) } }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
    }
}

import SwiftUI
import SwiftData

@main struct MyApp: App {
    let container: ModelContainer
    @State private var workspace: Workspace

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Node.self, NoteBlock.self, Connection.self, Theme.self)
        } catch {
            fatalError("Не удалось открыть базу заметок: \(error)")
        }
        self.container = container
        _workspace = State(initialValue: Workspace(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
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
        CommandGroup(replacing: .newItem) {
            Button("Новая заметка") { ws.createNodeAtViewCenter() }
                .keyboardShortcut("n")
            Button("Новая заметка во вкладке") { ws.newNoteTab() }
                .keyboardShortcut("t")
        }
        CommandMenu("Холст") {
            Button("Все заметки…") { ws.showAllNotes = true }
                .keyboardShortcut("k")
            Button("К центру") { ws.goHome() }
                .keyboardShortcut("0")
            Button("Приблизить") { withAnimation(.snappy) { ws.zoom(by: 1.25) } }
                .keyboardShortcut("=")
            Button("Отдалить") { withAnimation(.snappy) { ws.zoom(by: 0.8) } }
                .keyboardShortcut("-")
            Button("Удалить выбранное") { ws.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        CommandMenu("Вкладки") {
            Button("Холст") { ws.selectTab(at: 0) }
                .keyboardShortcut("1")
            ForEach(2..<10) { i in
                Button("Вкладка \(i - 1)") { ws.selectTab(at: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")))
            }
            Divider()
            Button("Следующая вкладка") { ws.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Предыдущая вкладка") { ws.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Закрыть вкладку") { if let id = ws.activeTab { ws.close(tab: id) } }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
    }
}

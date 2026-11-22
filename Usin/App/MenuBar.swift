#if os(macOS)
import AppKit
import SwiftUI
import UsinTools

/// Связь Usin с инструментами Mac. Значок в строке меню — панель инструментов (цифры Mac,
/// быстрые действия), а её кнопки «Новая заметка», «Открыть Usin», «Настройки» приходят сюда.
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    var workspace: Workspace?
    /// Открыть окно холста, когда все окна закрыты. Приходит из ContentView (`openWindow`).
    var openMainWindow: (() -> Void)?

    private var defaultsObserver: NSObjectProtocol?
    private var shownInMenuBar: Bool?

    private var isWanted: Bool {
        UserDefaults.standard.object(forKey: AppSettings.menuBarIconKey) as? Bool ?? true
    }

    func start() {
        ToolsHost.openApp = { [weak self] in self?.showWindow() }
        ToolsHost.newNote = { [weak self] in self?.newNote() }
        ToolsHost.openSettings = { [weak self] page in self?.openSettings(page.map { .tool($0) }) }
        ToolsHost.checkForUpdates = { Task { await Updater.shared.check(manual: true) } }
        workspace?.installToolNotes()

        ToolsRuntime.start()
        update()
        // Переключатель в настройках пишет в UserDefaults — значок появляется и исчезает сразу.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        guard shownInMenuBar != isWanted else { return }
        shownInMenuBar = isWanted
        ToolsRuntime.setMenuBarVisible(isWanted)
    }

    private func newNote() {
        showWindow()
        workspace?.newNoteTab()
    }

    /// Окно с холстом: вывести вперёд, а если его закрыли — открыть заново.
    func showWindow() {
        NSApp.activate()
        if let window = MainWindow.current {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindow {
            openMainWindow()
        } else {
            // Окно ещё ни разу не открывалось: «повторный запуск» заставляет SwiftUI создать его.
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    /// Тот же пункт «Настройки…» (⌘,), что в меню приложения: его добавляет сцена Settings.
    /// Если окно настроек уже открыто, оно просто переходит на нужную страницу.
    func openSettings(_ page: SettingsPage? = nil) {
        if let page { workspace?.settingsPage = page }
        NSApp.activate()
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        if let appMenu, let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            appMenu.performActionForItem(at: index)
        }
    }
}

enum MainWindow {
    static let id = "main"

    /// Окна сцены `WindowGroup(id: "main")` SwiftUI называет «main-AppWindow-N».
    static var current: NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue.hasPrefix(id) == true && (window.isVisible || window.isMiniaturized)
        }
    }
}

/// Значок в Dock: без него Usin живёт только в строке меню.
enum DockPolicy {
    static func apply(showInDock: Bool) {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // После смены политики окна уходят на задний план — возвращаем Usin вперёд.
        DispatchQueue.main.async { NSApp.activate() }
    }

    static var showInDock: Bool {
        UserDefaults.standard.object(forKey: AppSettings.showInDockKey) as? Bool ?? true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !DockPolicy.showInDock {
            // Без Dock значок в строке меню обязателен: иначе приложение не открыть.
            UserDefaults.standard.set(true, forKey: AppSettings.menuBarIconKey)
            DockPolicy.apply(showInDock: false)
        }
        StatusItemController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ToolsRuntime.willTerminate()
    }
}
#endif

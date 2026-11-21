#if os(macOS)
import AppKit
import SwiftUI

/// Значок Usin в строке меню: быстрая заметка, окно, настройки, обновления.
/// Сделан на AppKit (как в Singluse): позже сюда добавятся цифры процессора и пункты модулей.
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    var workspace: Workspace?
    /// Открыть окно холста, когда все окна закрыты. Приходит из ContentView (`openWindow`).
    var openMainWindow: (() -> Void)?

    private var item: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    private var isWanted: Bool {
        UserDefaults.standard.object(forKey: AppSettings.menuBarIconKey) as? Bool ?? true
    }

    func start() {
        update()
        // Переключатель в настройках пишет в UserDefaults — значок появляется и исчезает сразу.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        if isWanted, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Usin")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !isWanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    // Меню собирается при каждом открытии — так названия всегда на выбранном языке.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(tr("Новая заметка"), to: menu, action: #selector(newNote))
        add(tr("Открыть Usin"), to: menu, action: #selector(showWindow))
        menu.addItem(.separator())
        add(tr("Настройки") + "…", to: menu, action: #selector(openSettings))
        add(tr("Проверить обновления") + "…", to: menu, action: #selector(checkForUpdates))
        menu.addItem(.separator())
        add(tr("Выйти из Usin"), to: menu, action: #selector(quit))
    }

    private func add(_ title: String, to menu: NSMenu, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func newNote() {
        showWindow()
        workspace?.newNoteTab()
    }

    /// Окно с холстом: вывести вперёд, а если его закрыли — открыть заново.
    @objc private func showWindow() {
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
    @objc private func openSettings() {
        NSApp.activate()
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        if let appMenu, let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            appMenu.performActionForItem(at: index)
        }
    }

    @objc private func checkForUpdates() {
        Task { await Updater.shared.check(manual: true) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
}
#endif

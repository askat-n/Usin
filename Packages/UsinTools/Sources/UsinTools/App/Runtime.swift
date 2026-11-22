import AppKit
import Combine
import Foundation

/// Заметка Usin, которую пишут инструменты: встреча, диктовка, запись из буфера, быстрая заметка.
public struct ToolNote: Sendable {
    public enum Mode: Sendable {
        /// Весь текст заново (встреча дописывается по ходу). Заметку из корзины не возвращаем.
        case replace
        /// Строки добавляются в конец (заметка «Диктовки»). Если её удалили — появится новая.
        case append
    }

    /// Встреча пишет всегда в свою заметку — так она обновляется, а не множится.
    public var id: UUID
    public var title: String
    public var lines: [String]
    /// Картинка из буфера обмена (PNG).
    public var image: Data?

    public init(id: UUID = UUID(), title: String, lines: [String], image: Data? = nil) {
        self.id = id
        self.title = title
        self.lines = lines
        self.image = image
    }

    /// Название из первых слов текста.
    static func title(from text: String, fallback: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !first.isEmpty else { return fallback }
        return first.count > 60 ? String(first.prefix(57)) + "…" : first
    }
}

/// Что инструменты просят у приложения Usin: открыть окно, заметку, настройки, проверить обновления.
/// Приложение заполняет эти действия при запуске.
@MainActor
public enum ToolsHost {
    public static var openApp: () -> Void = {}
    public static var newNote: () -> Void = {}
    /// `nil` — просто окно настроек, иначе нужная страница инструмента.
    public static var openSettings: (ToolPage?) -> Void = { _ in }
    public static var checkForUpdates: () -> Void = {}

    /// Создать заметку или обновить её. Возвращает id заметки, в которую записано (`nil` — не записано).
    public static var writeNote: (ToolNote, ToolNote.Mode) -> UUID? = { _, _ in nil }
    /// Есть ли такая заметка (не в корзине).
    public static var hasNote: (UUID) -> Bool = { _ in false }
    /// Открыть заметку во вкладке Usin.
    public static var openNote: (UUID) -> Void = { _ in }
    /// Заметки, отмеченные «Для ИИ», одним текстом не длиннее `limit` знаков, и сколько их всего.
    public static var notesForAI: (_ limit: Int) -> (text: String, count: Int) = { _ in ("", 0) }
}

/// Запуск инструментов Mac внутри Usin.
@MainActor
public enum ToolsRuntime {
    /// Состояние, которое показывают настройки.
    public final class State: ObservableObject {
        /// Singluse запущен: инструменты Usin ждут, иначе чёлка, мышь и голос работали бы дважды.
        @Published public internal(set) var waitingForSingluse = false
        @Published public internal(set) var isRunning = false
    }

    public static let state = State()
    private static let menuBar = MenuBarController()
    private static var menuBarWanted = false
    private static var runningAppsObservation: NSKeyValueObservation?

    nonisolated static let singluseBundleID = "com.askatbek.singluse"

    /// Вызывается один раз при запуске Usin.
    public static func start() {
        SingluseImport.runIfNeeded()
        if isSingluseRunning {
            state.waitingForSingluse = true
            // Singluse живёт только в строке меню, а о закрытии таких приложений NSWorkspace
            // уведомления не присылает. Поэтому следим за самим списком запущенных приложений.
            runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !isSingluseRunning { startModules() }
                    }
                }
            }
        } else {
            startModules()
        }
    }

    private static func startModules() {
        guard !state.isRunning else { return }
        runningAppsObservation?.invalidate()
        runningAppsObservation = nil
        state.waitingForSingluse = false
        state.isRunning = true
        Coordinator.shared.start()
        Coordinator.shared.widgets.start()
        // Виджеты рабочего стола (systemWidgets) ждут своё расширение и группу приложений:
        // без них запись в общую папку вызвала бы вопрос macOS «доступ к данным других приложений».
        applyMenuBar()
    }

    /// Перед выходом: сохранить историю буфера обмена.
    public static func willTerminate() {
        guard state.isRunning else { return }
        Coordinator.shared.clipboard.saveNow()
    }

    // MARK: - Строка меню

    /// Значок Usin в строке меню с панелью (цифры Mac, приложения, быстрые действия).
    public static func setMenuBarVisible(_ visible: Bool) {
        // Панель читает настройки инструментов: сначала перенос из Singluse, иначе первый запуск
        // увидел бы настройки по умолчанию.
        SingluseImport.runIfNeeded()
        menuBarWanted = visible
        applyMenuBar()
    }

    private static func applyMenuBar() {
        if menuBarWanted { menuBar.install() } else { menuBar.remove() }
    }

    public static func showMenuBarPanel() {
        if menuBar.isInstalled { menuBar.open() } else { ToolsHost.openApp() }
    }

    // MARK: - Singluse

    static var isSingluseRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: singluseBundleID).isEmpty
    }

    public static func quitSingluse() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: singluseBundleID) {
            app.terminate()
        }
    }
}

/// Один раз переносит настройки и данные Singluse в Usin: модели речи, обои, историю буфера,
/// записи встреч. Файлы копируются (на APFS — мгновенно и без лишнего места), Singluse не меняется.
enum SingluseImport {
    private static let doneKey = "tools.importedFromSingluse"

    /// Ключи, которые остаются у каждого приложения своими.
    private static let skippedKeys: Set<String> = [
        "AppleLanguages", "languageChosen", "launchedBefore", "migratedLaunchAtLogin",
        "showMenuBarIcon", "autoCheckUpdates", "skippedUpdateVersion", "updateLastCheck",
    ]

    /// Что лежит в Application Support/Singluse и переезжает в Application Support/Usin.
    private static let items = [
        "Whisper", "Parakeet", "Wallpapers", "LockFrames", "Meetings", "ClipImages",
        "clipboard.json", "dictations.json",
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        if let old = UserDefaults(suiteName: ToolsRuntime.singluseBundleID)?.persistentDomain(forName: ToolsRuntime.singluseBundleID) {
            for (key, value) in old where !skippedKeys.contains(key) && !key.hasPrefix("NS") && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let source = support.appendingPathComponent("Singluse", isDirectory: true)
        let target = support.appendingPathComponent("Usin", isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in items {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.copyItem(at: from, to: to)
            } catch {
                NSLog("Usin: import of \(name) from Singluse failed: \(error)")
            }
        }
    }
}

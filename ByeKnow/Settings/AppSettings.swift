import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case ru, en

    var id: String { rawValue }
    var title: String { self == .ru ? "Русский" : "English" }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: tr("Системное")
        case .light: tr("Светлое")
        case .dark: tr("Тёмное")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Настройки, которые человек меняет под себя. Хранятся на устройстве.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    static let holdOptions: [Double] = [1.0, 1.25, 1.5, 2.0]

    private let defaults = UserDefaults.standard

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "settings.language") }
    }

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "settings.appearance") }
    }

    /// Сколько секунд держать палец на пустом месте холста, чтобы появилась заметка.
    var holdDuration: Double {
        didSet { defaults.set(holdDuration, forKey: "settings.holdDuration") }
    }

    /// Форма, с которой появляется новая заметка.
    var defaultShape: NodeShape {
        didSet { defaults.set(defaultShape.rawValue, forKey: "settings.defaultShape") }
    }

    var showGrid: Bool {
        didSet { defaults.set(showGrid, forKey: "settings.showGrid") }
    }

    private init() {
        let systemIsRussian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? true
        language = AppLanguage(rawValue: defaults.string(forKey: "settings.language") ?? "")
            ?? (systemIsRussian ? .ru : .en)
        appearance = AppAppearance(rawValue: defaults.string(forKey: "settings.appearance") ?? "") ?? .system
        let hold = defaults.double(forKey: "settings.holdDuration")
        holdDuration = hold > 0 ? hold : 1.25
        defaultShape = NodeShape(rawValue: defaults.string(forKey: "settings.defaultShape") ?? "") ?? .card
        showGrid = defaults.object(forKey: "settings.showGrid") as? Bool ?? true
    }
}

/// Перевод строки интерфейса. Текст в коде — по-русски, английский берётся из словаря.
func tr(_ russian: String) -> String {
    AppSettings.shared.language == .en ? (englishStrings[russian] ?? russian) : russian
}

private let englishStrings: [String: String] = [
    // Цвета
    "Обычный": "Default",
    "Красный": "Red",
    "Оранжевый": "Orange",
    "Жёлтый": "Yellow",
    "Зелёный": "Green",
    "Бирюзовый": "Teal",
    "Синий": "Blue",
    "Фиолетовый": "Purple",
    "Розовый": "Pink",

    // Меню и вкладки
    "Новая заметка": "New note",
    "Новая заметка во вкладке": "New note in tab",
    "Новая заметка во вкладке (⌘T)": "New note in tab (⌘T)",
    "Холст": "Canvas",
    "Все заметки…": "All notes…",
    "Все заметки": "All notes",
    "Все заметки (⌘K)": "All notes (⌘K)",
    "К сфере ByeKnow": "Back to the ByeKnow sphere",
    "Приблизить": "Zoom in",
    "Отдалить": "Zoom out",
    "Удалить выбранное": "Delete selection",
    "Вкладки": "Tabs",
    "Вкладка": "Tab",
    "Следующая вкладка": "Next tab",
    "Предыдущая вкладка": "Previous tab",
    "Закрыть вкладку": "Close tab",

    // Фигуры, блоки, стрелки
    "Карточка": "Card",
    "Круг": "Circle",
    "Квадрат": "Square",
    "Стикер": "Sticker",
    "Текст": "Text",
    "Заголовок": "Heading",
    "Чек-лист": "Checklist",
    "Картинка": "Image",
    "Ссылка": "Link",
    "Разделитель": "Divider",
    "Прямая": "Straight",
    "Изогнутая": "Curved",
    "Стрелка": "Arrow",
    "Точка": "Dot",
    "Без наконечника": "No arrowhead",

    // Холст
    "Пока нет заметок": "No notes yet",
    "Удержи палец на пустом месте холста, чтобы создать первую": "Hold your finger on an empty spot of the canvas to create one",
    "Поиск по заметкам": "Search notes",
    "Готово": "Done",
    "Тяни к другой фигуре — стрелка. Нажми — новая связанная заметка": "Drag to another shape to draw an arrow. Tap for a new linked note",
    "Тяни, чтобы изогнуть. Двойной тап — выпрямить": "Drag to bend. Double-tap to straighten",
    "Удержи палец на пустом месте — появится заметка": "Hold your finger on an empty spot to create a note",

    // Заметка
    "Название": "Title",
    "На холсте": "On canvas",
    "Удалить заметку": "Delete note",
    "Пиши… или «/» для блоков": "Write… or type “/” for blocks",
    "Пункт": "Item",
    "Нажми — меню. Потяни — переставить строку": "Tap for menu. Drag to move the line",
    "Картинку нельзя превратить в другой блок — иначе она пропадёт": "An image can't become another block — it would be lost",
    "Картинка и разделитель недоступны: в строке есть текст": "Image and divider are unavailable: this line has text",
    "Превратить в": "Turn into",
    "Добавить строку ниже": "Add line below",
    "Удалить": "Delete",
    "Заменить из Фото": "Replace from Photos",
    "Из Фото": "From Photos",
    "Из файла": "From file",
    "или перетащи картинку сюда": "or drag an image here",
    "Открыть": "Open",
    "Открыть ссылку": "Open link",

    // Темы и панель
    "Без темы": "No theme",
    "Новая тема…": "New theme…",
    "Новая тема": "New theme",
    "Тема": "Theme",
    "Создать": "Create",
    "Отмена": "Cancel",
    "Все": "All",
    "Переименовать": "Rename",
    "Переименовать тему": "Rename theme",
    "Цвет": "Color",
    "Удалить тему": "Delete theme",
    "Цвет фигуры": "Shape color",
    "Цвет текста": "Text color",
    "Открыть во вкладке": "Open in tab",
    "Пунктир": "Dashed",
    "Цвет стрелки": "Arrow color",
    "Развернуть": "Reverse",

    // Настройки
    "Настройки": "Settings",
    "Язык": "Language",
    "Оформление": "Appearance",
    "Тема оформления": "Theme",
    "Системное": "System",
    "Светлое": "Light",
    "Тёмное": "Dark",
    "Удержание для новой заметки": "Hold to create a note",
    "с": "s",
    "Форма новой заметки": "New note shape",
    "Сетка из точек": "Dot grid",
    "О приложении": "About",
    "Версия": "Version",

    // Синхронизация
    "Синхронизация": "Sync",
    "Подключить Google Drive": "Connect Google Drive",
    "Подключение…": "Connecting…",
    "Синхронизация…": "Syncing…",
    "Синхронизировать сейчас": "Sync now",
    "Отключить Google Drive": "Disconnect Google Drive",
    "Последняя синхронизация": "Last sync",
    "Ещё не синхронизировалось": "Not synced yet",
    "Подключено": "Connected",
    "Ошибка синхронизации": "Sync error",
    "Заметки хранятся в скрытой папке приложения на твоём Google Drive и одинаковы на iPhone, iPad и Mac. Если переустановить приложение, просто подключи Drive снова — всё вернётся.":
        "Notes are kept in a hidden app folder on your Google Drive and stay the same on iPhone, iPad and Mac. If you reinstall the app, just connect Drive again and everything comes back.",
    "На Google Drive найдены заметки": "Notes found on Google Drive",
    "На этом устройстве тоже есть заметки. Если подключить Google Drive, всё, что сейчас на этом устройстве, сотрётся и заменится заметками с Google Drive. Согласен?":
        "This device has notes too. If you connect Google Drive, everything on this device will be erased and replaced with the notes from Google Drive. Do you agree?",
    "Да, стереть и подключить": "Yes, erase and connect",
    "Нет": "No",
    "Войди в Google ещё раз": "Sign in to Google again",
    "Нет интернета или Google не отвечает": "No internet or Google is not responding",
]

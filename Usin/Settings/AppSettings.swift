import SwiftUI

/// Язык интерфейса — один на всё приложение: холст, заметки, настройки и инструменты Mac.
enum AppLanguage: String, CaseIterable, Identifiable {
    case ru, en, es
    case zhHans = "zh-Hans"
    case ar, fr, vi, ko, tl

    var id: String { rawValue }

    /// Название на самом языке: человек должен найти свой, не зная текущего.
    var title: String {
        switch self {
        case .ru: "Русский"
        case .en: "English"
        case .es: "Español"
        case .zhHans: "简体中文"
        case .ar: "العربية"
        case .fr: "Français"
        case .vi: "Tiếng Việt"
        case .ko: "한국어"
        case .tl: "Tagalog"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Арабский читается справа налево — окно настроек зеркалится вместе с ним. Холст не зеркалится.
    var layoutDirection: LayoutDirection { self == .ar ? .rightToLeft : .leftToRight }

    /// Переводы этого языка: `<язык>.lproj` в приложении (собирает `Localization/make-strings.py`).
    var bundle: Bundle { Self.bundles[self] ?? .main }

    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues: allCases.map { language in
        (language, Bundle.main.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main)
    })

    /// Первый язык системы, который знает Usin; если ни одного — английский.
    static var system: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let language = Locale.Language(identifier: identifier)
            switch language.languageCode?.identifier {
            case "zh": return .zhHans
            case "fil": return .tl
            case let code?: if let known = AppLanguage(rawValue: code) { return known }
            case nil: continue
            }
        }
        return .en
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L("Системное")
        case .light: L("Светлое")
        case .dark: L("Тёмное")
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

enum CanvasStyle: String, CaseIterable, Identifiable {
    case cosmos, terminal, classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cosmos: L("Космос")
        case .terminal: L("Терминал")
        case .classic: L("Классический")
        }
    }

    /// Тёмные стили всегда в тёмном оформлении и с анимацией.
    var isDark: Bool { self != .classic }
}

/// Настройки, которые человек меняет под себя. Хранятся на устройстве.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    /// Mac: значок в Dock и в строке меню. Хранятся через @AppStorage — их читает и сцена строки меню.
    static let showInDockKey = "settings.showInDock"
    static let menuBarIconKey = "settings.showMenuBarIcon"
    static let holdOptions: [Double] = [1.0, 1.25, 1.5, 2.0]

    private let defaults = UserDefaults.standard

    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageKey)
            // Системные меню, окна выбора файла и даты — на том же языке со следующего запуска.
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Его же читают инструменты Mac (`ToolsLanguage`).
    static let languageKey = "settings.language"

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

    /// «Космос» — тёмный живой холст с анимацией, «Классический» — светлый спокойный.
    var canvasStyle: CanvasStyle {
        didSet { defaults.set(canvasStyle.rawValue, forKey: "settings.canvasStyle") }
    }

    var isCosmos: Bool { canvasStyle == .cosmos }
    var isTerminal: Bool { canvasStyle == .terminal }

    /// Движение в тёмных стилях: звёзды, огоньки на стрелках, курсор, развёртка.
    var cosmosMotion: Bool {
        didSet { defaults.set(cosmosMotion, forKey: "settings.cosmosMotion") }
    }

    /// Живой граф: заметки плавают и пружинят во всех стилях.
    var classicMotion: Bool {
        didSet { defaults.set(classicMotion, forKey: "settings.classicMotion") }
    }

    /// В «Космосе» и «Терминале» оформление всегда тёмное.
    var effectiveColorScheme: ColorScheme? { canvasStyle.isDark ? .dark : appearance.colorScheme }

    private init() {
        if let saved = AppLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") {
            language = saved
        } else {
            // Запоминаем сразу: инструменты Mac читают язык из настроек и должны говорить на том же.
            let detected = AppLanguage.system
            language = detected
            defaults.set(detected.rawValue, forKey: Self.languageKey)
        }
        appearance = AppAppearance(rawValue: defaults.string(forKey: "settings.appearance") ?? "") ?? .system
        let hold = defaults.double(forKey: "settings.holdDuration")
        holdDuration = hold > 0 ? hold : 1.25
        defaultShape = NodeShape(rawValue: defaults.string(forKey: "settings.defaultShape") ?? "") ?? .card
        showGrid = defaults.object(forKey: "settings.showGrid") as? Bool ?? true
        canvasStyle = CanvasStyle(rawValue: defaults.string(forKey: "settings.canvasStyle") ?? "") ?? .cosmos
        cosmosMotion = defaults.object(forKey: "settings.cosmosMotion") as? Bool ?? true
        classicMotion = defaults.object(forKey: "settings.classicMotion") as? Bool ?? true
    }
}

/// Перевод строки интерфейса. Ключ — русский текст, переводы — `Localization/app` (таблица App).
/// Язык читается из настроек, поэтому экран перерисовывается сразу, как только его сменили.
func L(_ key: String) -> String {
    AppSettings.shared.language.bundle.localizedString(forKey: key, value: key, table: "App")
}

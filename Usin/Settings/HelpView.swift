import SwiftUI

/// «Как пользоваться»: коротко обо всём и горячие клавиши.
struct HelpView: View {
    private var en: Bool { AppSettings.shared.language == .en }
    private func t(_ ru: String, _ english: String) -> String { en ? english : ru }

    var body: some View {
        List {
            Section {
                Text(t("Usin — заметки на бесконечном холсте. В центре сфера Usin, от неё ты строишь свою схему: заметки, стрелки, темы.",
                       "Usin is notes on an infinite canvas. The Usin sphere sits in the center, and you build your map around it: notes, arrows, themes."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(t("Холст", "Canvas")) {
                item("hand.tap", t("Удержи палец (или мышь) на пустом месте — появится заметка",
                                   "Hold your finger (or mouse) on an empty spot to create a note"))
                item("hand.draw", t("Тяни пустое место — двигаешь холст. Щипок или ⌘ + прокрутка — масштаб",
                                    "Drag an empty spot to pan. Pinch or ⌘ + scroll to zoom"))
                item("scope", t("Кнопка ◎ справа — вернуться к сфере Usin",
                                "The ◎ button on the right takes you back to the Usin sphere"))
                item("sparkles", t("Настройки → Оформление: «Космос» (живой космос), «Терминал» (как экран компьютера) или «Классический». Анимацию можно выключить",
                                   "Settings → Appearance: “Cosmos” (living space), “Terminal” (computer screen look) or “Classic”. Animation can be turned off"))
            }

            Section(t("Заметки и стрелки", "Notes and arrows")) {
                item("hand.point.up", t("Нажми на заметку — выбрать. Снизу панель: форма, цвет, цвет текста, тема, удалить",
                                        "Tap a note to select it. The bottom bar has shape, color, text color, theme, delete"))
                item("rectangle.on.rectangle", t("Два раза нажми на заметку — она откроется во вкладке сверху",
                                                 "Double-tap a note to open it in a tab at the top"))
                item("plus.circle", t("Синий «+» справа от заметки: потяни к другой заметке — стрелка; просто нажми — новая связанная заметка",
                                      "The blue “+” next to a note: drag it to another note for an arrow; tap it for a new linked note"))
                item("point.topleft.down.to.point.bottomright.curvepath", t("Нажми на стрелку и тяни точку посередине — стрелка изогнётся",
                                                                            "Tap an arrow and drag its middle point to bend it"))
            }

            Section(t("Внутри заметки", "Inside a note")) {
                item("slash.circle", t("Набери «/» в пустой строке — меню: заголовок, чек-лист, картинка, ссылка, разделитель",
                                       "Type “/” on an empty line for a menu: heading, checklist, image, link, divider"))
                item("return", t("Enter — новая строка. В чек-листе Enter на пустом пункте — выход из списка",
                                 "Enter starts a new line. In a checklist, Enter on an empty item leaves the list"))
                item("line.3.horizontal", t("≡ слева от строки: нажми — меню, потяни — переставить строку",
                                            "≡ to the left of a line: tap for a menu, drag to move the line"))
            }

            Section(t("Темы, синхронизация, корзина", "Themes, sync, trash")) {
                item("tag", t("Темы сверху холста: нажми на тему — останутся только её заметки",
                              "Themes at the top of the canvas: tap one to show only its notes"))
                item("checkmark.icloud", t("Облачко сверху: галочка — всё сохранено в Google Drive, мигает — сохраняется",
                                           "The cloud at the top: a checkmark means everything is saved to Google Drive, blinking means saving"))
                item("trash", t("Удалённые заметки 30 дней лежат в корзине (Настройки → Корзина). Сразу после удаления можно нажать «Отменить»",
                                "Deleted notes stay in the trash for 30 days (Settings → Trash). Right after deleting you can tap “Undo”"))
            }

            Section {
                ForEach(shortcuts, id: \.keys) { shortcut in
                    HStack(alignment: .firstTextBaseline) {
                        Text(shortcut.keys)
                            .font(.callout.monospaced().weight(.medium))
                            .frame(minWidth: 70, alignment: .leading)
                        Text(shortcut.action)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("Горячие клавиши (Mac и iPad с клавиатурой)", "Keyboard shortcuts (Mac and iPad with keyboard)"))
            }
        }
        .navigationTitle(t("Как пользоваться", "How to use"))
    }

    private func item(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
        }
    }

    private var shortcuts: [(keys: String, action: String)] {
        [
            ("⌘N", t("Новая заметка", "New note")),
            ("⌘T", t("Новая заметка во вкладке", "New note in a tab")),
            ("⌘↩", t("Открыть выбранную заметку", "Open the selected note")),
            ("⌘D", t("Дублировать заметку", "Duplicate note")),
            ("⌘⌫", t("Переместить в корзину", "Move to trash")),
            ("⌘Z", t("Отменить", "Undo")),
            ("⇧⌘Z", t("Повторить", "Redo")),
            ("⌘F / ⌘K", t("Поиск по заметкам", "Search notes")),
            ("⌘W", t("Закрыть вкладку", "Close tab")),
            ("⇧⌘T", t("Вернуть закрытую вкладку", "Reopen closed tab")),
            ("⌘1", t("Холст", "Canvas")),
            ("⌘2…⌘9", t("Вкладки по порядку", "Tabs in order")),
            ("⇧⌘] / ⇧⌘[", t("Следующая / предыдущая вкладка", "Next / previous tab")),
            ("⌘= / ⌘−", t("Приблизить / отдалить", "Zoom in / out")),
            ("⌘0", t("К сфере Usin", "Back to the sphere")),
            ("⌘,", t("Настройки", "Settings")),
        ]
    }
}

import SwiftUI

/// «Как пользоваться»: коротко обо всём и горячие клавиши.
struct HelpView: View {
    var body: some View {
        List {
            Section {
                Text(L("Usin — заметки на бесконечном холсте. В центре сфера Usin, от неё ты строишь свою схему: заметки, стрелки, темы."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L("Холст")) {
                item("hand.tap", L("Удержи палец (или мышь) на пустом месте — появится заметка"))
                item("hand.draw", L("Тяни пустое место — двигаешь холст. Щипок или ⌘ + прокрутка — масштаб"))
                item("scope", L("Кнопка ◎ справа — вернуться к сфере Usin"))
                item("sparkles", L("Настройки → Оформление: «Космос» (живой космос), «Терминал» (как экран компьютера) или «Классический». Анимацию можно выключить"))
            }

            Section(L("Заметки и стрелки")) {
                item("hand.point.up", L("Нажми на заметку — выбрать. Снизу панель: форма, цвет, цвет текста, тема, удалить"))
                item("rectangle.on.rectangle", L("Два раза нажми на заметку — она откроется во вкладке сверху"))
                item("plus.circle", L("Синий «+» справа от заметки: потяни к другой заметке — стрелка; просто нажми — новая связанная заметка"))
                item("point.topleft.down.to.point.bottomright.curvepath", L("Нажми на стрелку и тяни точку посередине — стрелка изогнётся"))
            }

            Section(L("Внутри заметки")) {
                item("slash.circle", L("Набери «/» в пустой строке — меню: заголовок, чек-лист, картинка, ссылка, разделитель"))
                item("return", L("Enter — новая строка. В чек-листе Enter на пустом пункте — выход из списка"))
                item("line.3.horizontal", L("≡ слева от строки: нажми — меню, потяни — переставить строку"))
            }

            Section(L("Темы, синхронизация, корзина")) {
                item("tag", L("Темы сверху холста: нажми на тему — останутся только её заметки"))
                item("checkmark.icloud", L("Облачко сверху: галочка — всё сохранено в Google Drive, мигает — сохраняется"))
                item("trash", L("Удалённые заметки 30 дней лежат в корзине (Настройки → Корзина). Сразу после удаления можно нажать «Отменить»"))
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
                Text(L("Горячие клавиши (Mac и iPad с клавиатурой)"))
            }
        }
        .navigationTitle(L("Как пользоваться"))
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
            ("⌘N", L("Новая заметка")),
            ("⌘T", L("Новая заметка во вкладке")),
            ("⌘↩", L("Открыть выбранную заметку")),
            ("⌘D", L("Дублировать заметку")),
            ("⌘⌫", L("Переместить в корзину")),
            ("⌘Z", L("Отменить")),
            ("⇧⌘Z", L("Повторить")),
            ("⌘F / ⌘K", L("Поиск по заметкам")),
            ("⌘W", L("Закрыть вкладку")),
            ("⇧⌘T", L("Вернуть закрытую вкладку")),
            ("⌘1", L("Холст")),
            ("⌘2…⌘9", L("Вкладки по порядку")),
            ("⇧⌘] / ⇧⌘[", L("Следующая / предыдущая вкладка")),
            ("⌘= / ⌘−", L("Приблизить / отдалить")),
            ("⌘0", L("К сфере Usin")),
            ("⌘,", L("Настройки")),
        ]
    }
}

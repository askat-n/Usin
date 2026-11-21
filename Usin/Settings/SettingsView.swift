import SwiftUI
import AuthenticationServices
import SwiftData
#if os(macOS)
import ServiceManagement
#endif

/// Разделы настроек. На Mac — строки боковой панели, как в Системных настройках; на iPhone — список.
/// Модули Mac (чёлка, диктовка, буфер обмена…) добавятся сюда отдельными строками.
enum SettingsPage: String, Hashable, CaseIterable, Identifiable {
    case general, notes, help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: tr("Основные")
        case .notes: tr("Заметки")
        case .help: tr("Справка")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .notes: "circle.hexagongrid.fill"
        case .help: "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .notes: .orange
        case .help: .blue
        }
    }
}

struct SettingsView: View {
    @Environment(Workspace.self) private var ws
    @Environment(SyncEngine.self) private var sync
    #if os(macOS)
    @Environment(NoteExporter.self) private var exporter
    @State private var page: SettingsPage? = .general
    #else
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsPage] = []
    #endif

    var body: some View {
        @Bindable var sync = sync
        container
            .onAppear(perform: takeRequestedPage)
            .onChange(of: ws.settingsPage) { takeRequestedPage() }
            .sheet(isPresented: $sync.needsReplaceConfirmation) {
                ReplaceConfirmation(
                    onYes: { Task { await sync.confirmReplace() } },
                    onNo: { sync.cancelConnect() }
                )
            }
    }

    /// Раздел, который попросили открыть (например, «Заметки» из значка синхронизации).
    private func takeRequestedPage() {
        guard let requested = ws.settingsPage else { return }
        #if os(macOS)
        page = requested
        #else
        path = [requested]
        #endif
        ws.settingsPage = nil
    }

    /// Точка у раздела — только там, где нужно что-то сделать.
    private func needsAttention(_ page: SettingsPage) -> Bool {
        guard page == .notes else { return false }
        if case .failed = sync.status { return true }
        #if os(macOS)
        if exporter.errorMessage != nil { return true }
        #endif
        return false
    }

    @ViewBuilder
    private func detail(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .notes: NotesSettingsPage()
        case .help: HelpView()
        }
    }

    #if os(macOS)
    private var container: some View {
        NavigationSplitView {
            List(selection: $page) {
                row(.general)
                row(.notes)
                Section {
                    row(.help)
                }
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            let current = page ?? .general
            NavigationStack {
                detail(current)
                    .navigationTitle(current.title)
            }
            .id(current)
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 500, idealHeight: 620)
    }

    private func row(_ page: SettingsPage) -> some View {
        SettingsRow(page: page, attention: needsAttention(page)).tag(page)
    }
    #else
    private var container: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(SettingsPage.allCases) { page in
                    NavigationLink(value: page) {
                        SettingsRow(page: page, attention: needsAttention(page))
                    }
                }
                Section {
                    LabeledContent("Usin", value: tr("Версия") + " " + appVersion)
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                detail(page).navigationTitle(page.title)
            }
            .navigationTitle(tr("Настройки"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Готово")) { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    #endif
}

/// Строка раздела: цветная плитка со значком, как в Системных настройках.
private struct SettingsRow: View {
    let page: SettingsPage
    var attention = false

    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: page.symbol, tint: page.tint, size: 22)
            Text(page.title)
            Spacer()
            if attention {
                Circle().fill(.orange).frame(width: 7, height: 7).help(tr("Нужно действие"))
            }
        }
    }
}

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.gradient))
    }
}

// MARK: - Основные

struct GeneralSettingsPage: View {
    #if os(macOS)
    @AppStorage(AppSettings.showInDockKey) private var showInDock = true
    @AppStorage(AppSettings.menuBarIconKey) private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    #endif

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Form {
            #if os(macOS)
            Section {
                Toggle(tr("Запускать при входе в систему"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if loginNeedsApproval {
                    LabeledContent {
                        Button(tr("Открыть")) { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text(tr("Нужно разрешить в Системных настройках"))
                    }
                }
                Toggle(tr("Значок в Dock"), isOn: $showInDock)
                    .onChange(of: showInDock) { _, show in
                        // Без Dock приложение открывается только из строки меню — значок там нужен обязательно.
                        if !show { showMenuBarIcon = true }
                        DockPolicy.apply(showInDock: show)
                    }
                Toggle(tr("Значок в строке меню"), isOn: $showMenuBarIcon)
                    .disabled(!showInDock)
            } header: {
                Text(tr("Приложение"))
            } footer: {
                Text(showInDock
                     ? tr("Из строки меню — новая заметка, настройки и обновления.")
                     : tr("Без значка в Dock Usin открывается из значка в строке меню."))
            }
            #endif

            Section(tr("Язык")) {
                Picker(tr("Язык"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                Picker(tr("Тема оформления"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(settings.canvasStyle.isDark)
            } header: {
                Text(tr("Оформление"))
            } footer: {
                if settings.canvasStyle.isDark {
                    Text(tr("Тёмные стили холста всегда в тёмном оформлении. Стиль холста — в разделе «Заметки»."))
                }
            }

            #if os(macOS)
            UpdatesSection()
            #endif
        }
        .formStyle(.grouped)
    }

    #if os(macOS)
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    #endif
}

// MARK: - Заметки

struct NotesSettingsPage: View {
    @Query(filter: #Predicate<Node> { $0.deletedAt != nil }) private var trashed: [Node]

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Form {
            Section(tr("Холст")) {
                Picker(tr("Стиль холста"), selection: $settings.canvasStyle) {
                    ForEach(CanvasStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if settings.canvasStyle.isDark {
                    Toggle(isOn: $settings.cosmosMotion) {
                        Text(tr("Анимация"))
                        Text(tr("Тёмные стили всегда в тёмном оформлении.") + " " + tr("Без анимации холст не тратит батарею."))
                    }
                }
                Toggle(isOn: $settings.classicMotion) {
                    Text(tr("Живой граф"))
                    Text(tr("Заметки плавают и пружинят, как граф: потяни заметку — соседи по стрелкам потянутся за ней."))
                }
                Picker(tr("Удержание для новой заметки"), selection: $settings.holdDuration) {
                    ForEach(AppSettings.holdOptions, id: \.self) { value in
                        Text(value.formatted(.number.precision(.fractionLength(0...2))) + " " + tr("с")).tag(value)
                    }
                }
                Picker(tr("Форма новой заметки"), selection: $settings.defaultShape) {
                    ForEach(NodeShape.allCases) { shape in
                        Label(shape.title, systemImage: shape.icon).tag(shape)
                    }
                }
                Toggle(tr("Сетка из точек"), isOn: $settings.showGrid)
            }

            Section(tr("Синхронизация")) {
                SyncSettings()
            }

            #if os(macOS)
            Section(tr("ИИ-ассистенты")) {
                ExportSettings()
            }
            #endif

            Section {
                NavigationLink {
                    TrashView()
                } label: {
                    LabeledContent {
                        if !trashed.isEmpty { Text("\(trashed.count)") }
                    } label: {
                        Label(tr("Корзина"), systemImage: "trash")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Google Drive

private struct SyncSettings: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(\.webAuthenticationSession) private var webAuth

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.icloud")
                .font(.title2)
                .foregroundStyle(sync.isConnected ? Color.accentColor : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Google Drive").font(.body.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if sync.status == .syncing || sync.status == .connecting {
                ProgressView().controlSize(.small)
            }
        }

        if sync.isConnected {
            Button {
                Task { await sync.syncNow() }
            } label: {
                Label(tr("Синхронизировать сейчас"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.status == .syncing)
            Button(role: .destructive) {
                sync.disconnect()
            } label: {
                Label(tr("Отключить Google Drive"), systemImage: "xmark.circle")
            }
        } else {
            if sync.status == .connecting {
                #if os(macOS)
                Text(tr("Войди в Google в открывшемся окне браузера — потом приложение подключится само."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Button(role: .cancel) {
                    sync.cancelConnecting()
                } label: {
                    Label(tr("Отмена"), systemImage: "xmark")
                }
            } else {
                Button {
                    Task { await sync.connect(using: webAuth) }
                } label: {
                    Label(tr("Подключить Google Drive"), systemImage: "link")
                }
            }
        }

        Text(tr("Заметки хранятся в скрытой папке приложения на твоём Google Drive и одинаковы на iPhone, iPad и Mac. Если переустановить приложение, просто подключи Drive снова — всё вернётся."))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var statusText: String {
        switch sync.status {
        case .connecting: return tr("Подключение…")
        case .syncing: return tr("Синхронизация…")
        case .failed(let message): return tr("Ошибка синхронизации") + ": " + message
        case .off, .idle:
            guard sync.isConnected else { return tr("Подключить Google Drive") }
            let account = sync.email.map { $0 + " · " } ?? ""
            if let last = sync.lastSync {
                return account + tr("Последняя синхронизация") + ": " + last.formatted(date: .omitted, time: .shortened)
            }
            return account + tr("Ещё не синхронизировалось")
        }
    }

    private var statusIsError: Bool {
        if case .failed = sync.status { return true }
        return false
    }
}

// MARK: - Экспорт для ИИ

#if os(macOS)
private struct ExportSettings: View {
    @Environment(NoteExporter.self) private var exporter

    var body: some View {
        Toggle(isOn: Binding(get: { exporter.isEnabled }, set: { exporter.setEnabled($0) })) {
            Label(tr("Заметки в папке Markdown"), systemImage: "folder.badge.gearshape")
        }
        if let folder = exporter.folderURL {
            LabeledContent(tr("Папка")) {
                Text(folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack {
                Button(tr("Другая папка…")) { exporter.chooseFolder() }
                Button(tr("Показать в Finder")) { exporter.revealInFinder() }
            }
        }
        if let error = exporter.errorMessage {
            Text(tr("Ошибка экспорта") + ": " + error)
                .font(.caption)
                .foregroundStyle(.red)
        } else if exporter.isEnabled, let last = exporter.lastExport {
            Text(tr("Обновлено") + ": " + last.formatted(date: .omitted, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text(tr("В папке — копия заметок с отметкой «Для ИИ» (✦): по файлу .md на заметку, подпапки — темы, стрелки — [[ссылки]]. Остальные заметки остаются личными и в папку не попадают. Её читают ИИ-ассистенты через MCP-сервер Usin. Записи ИИ из подпапки inbox Usin применяет сам."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif

/// «На Google Drive найдены заметки — стереть то, что на устройстве?» Да — красная, Нет — серая.
struct ReplaceConfirmation: View {
    let onYes: () -> Void
    let onNo: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .padding(.top, 8)
            Text(tr("На Google Drive найдены заметки"))
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(tr("На этом устройстве тоже есть заметки. Если подключить Google Drive, всё, что сейчас на этом устройстве, сотрётся и заменится заметками с Google Drive. Согласен?"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button {
                    dismiss()
                    onYes()
                } label: {
                    Text(tr("Да, стереть и подключить"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    dismiss()
                    onNo()
                } label: {
                    Text(tr("Нет"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.gray.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .interactiveDismissDisabled()
        .presentationDetents([.medium])
    }
}

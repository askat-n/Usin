import SwiftUI
import AuthenticationServices
import SwiftData

struct SettingsView: View {
    @Environment(SyncEngine.self) private var sync
    #if os(macOS)
    @Environment(NoteExporter.self) private var exporter
    #endif
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth
    @Query(filter: #Predicate<Node> { $0.deletedAt != nil }) private var trashed: [Node]

    private var trashCount: Int { trashed.count }

    var body: some View {
        @Bindable var settings = AppSettings.shared
        @Bindable var sync = sync

        NavigationStack {
            Form {
                Section(tr("Синхронизация")) {
                    syncSection
                }

                #if os(macOS)
                Section(tr("ИИ-ассистенты")) {
                    exportSection
                }
                #endif

                Section(tr("Язык")) {
                    Picker(tr("Язык"), selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section(tr("Оформление")) {
                    Picker(tr("Стиль холста"), selection: $settings.canvasStyle) {
                        ForEach(CanvasStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if settings.canvasStyle.isDark {
                        Toggle(tr("Анимация"), isOn: $settings.cosmosMotion)
                        Text(tr("Тёмные стили всегда в тёмном оформлении.") + " " + tr("Без анимации холст не тратит батарею."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(tr("Тема оформления"), selection: $settings.appearance) {
                            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                Section(tr("Холст")) {
                    Toggle(tr("Живой граф"), isOn: $settings.classicMotion)
                    Text(tr("Заметки плавают и пружинят, как граф: потяни заметку — соседи по стрелкам потянутся за ней."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                Section {
                    NavigationLink {
                        TrashView()
                    } label: {
                        LabeledContent {
                            if trashCount > 0 { Text("\(trashCount)") }
                        } label: {
                            Label(tr("Корзина"), systemImage: "trash")
                        }
                    }
                }

                #if os(macOS)
                Section(tr("Обновления")) {
                    UpdatesSection()
                }
                #endif

                Section(tr("О приложении")) {
                    NavigationLink {
                        HelpView()
                    } label: {
                        Label(tr("Как пользоваться"), systemImage: "questionmark.circle")
                    }
                    LabeledContent("Usin", value: tr("Версия") + " " + appVersion)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tr("Настройки"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Готово")) { dismiss() }
                }
            }
            .sheet(isPresented: $sync.needsReplaceConfirmation) {
                ReplaceConfirmation(
                    onYes: { Task { await sync.confirmReplace() } },
                    onNo: { sync.cancelConnect() }
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    // MARK: - Google Drive

    @ViewBuilder
    private var syncSection: some View {
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

    // MARK: - Экспорт для ИИ

    #if os(macOS)
    @ViewBuilder
    private var exportSection: some View {
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
    #endif

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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

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

import SwiftUI

/// Облачко как в Google Документах: видно, всё ли сохранено на Google Drive.
/// Нажал — подробности и «Синхронизировать сейчас».
struct SyncIndicator: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(Workspace.self) private var ws
    @State private var showDetails = false

    private enum State {
        case off, saved, saving, error

        var icon: String {
            switch self {
            case .off: "icloud.slash"
            case .saved: "checkmark.icloud"
            case .saving: "arrow.triangle.2.circlepath.icloud"
            case .error: "exclamationmark.icloud"
            }
        }
    }

    private var state: State {
        guard sync.isConnected else { return .off }
        switch sync.status {
        case .failed: return .error
        case .syncing, .connecting: return .saving
        case .off, .idle: return sync.hasUnsavedChanges ? .saving : .saved
        }
    }

    private var title: String {
        switch state {
        case .off: tr("Google Drive не подключён")
        case .saved: tr("Все изменения сохранены в Google Drive")
        case .saving: tr("Сохранение…")
        case .error: tr("Не удалось сохранить в Google Drive")
        }
    }

    var body: some View {
        Button {
            if state == .off { ws.openSettings(.notes) } else { showDetails = true }
        } label: {
            Image(systemName: state.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: state == .saving)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .animation(.snappy, value: state)
        .popover(isPresented: $showDetails) {
            details
                .presentationCompactAdaptation(.popover)
        }
    }

    private var color: Color {
        switch state {
        case .off, .saved: .secondary
        case .saving: .accentColor
        case .error: .red
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: state.icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(state == .error ? Color.red : Color.primary)
            if case .failed(let message) = sync.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let email = sync.email {
                Text(email).font(.caption).foregroundStyle(.secondary)
            }
            if let last = sync.lastSync {
                Text(tr("Последняя синхронизация") + ": " + last.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await sync.syncNow() }
            } label: {
                Label(tr("Синхронизировать сейчас"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.status == .syncing)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }
}

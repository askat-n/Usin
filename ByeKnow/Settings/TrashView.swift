import SwiftUI
import SwiftData

/// Корзина: удалённые заметки хранятся 30 дней, их можно вернуть или удалить навсегда.
struct TrashView: View {
    @Environment(Workspace.self) private var ws
    @Query(filter: #Predicate<Node> { $0.deletedAt != nil }, sort: \Node.deletedAt, order: .reverse)
    private var trashed: [Node]
    @State private var confirmEmpty = false
    @State private var confirmDelete: Node?

    var body: some View {
        List {
            if !trashed.isEmpty {
                Section {
                    ForEach(trashed) { node in
                        row(node)
                    }
                } footer: {
                    Text(tr("Заметки удаляются навсегда через 30 дней после попадания в корзину."))
                }
            }
        }
        .overlay {
            if trashed.isEmpty {
                ContentUnavailableView(tr("Корзина пуста"), systemImage: "trash",
                                       description: Text(tr("Удалённые заметки хранятся здесь 30 дней.")))
            }
        }
        .navigationTitle(tr("Корзина"))
        .toolbar {
            if !trashed.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(tr("Очистить"), role: .destructive) { confirmEmpty = true }
                        .tint(.red)
                }
            }
        }
        .confirmationDialog(tr("Очистить корзину?"), isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button(tr("Удалить все навсегда"), role: .destructive) { withAnimation { ws.emptyTrash() } }
            Button(tr("Отмена"), role: .cancel) {}
        } message: {
            Text(tr("Заметки из корзины удалятся на всех устройствах. Это нельзя отменить."))
        }
        .confirmationDialog(tr("Удалить навсегда?"),
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button(tr("Удалить навсегда"), role: .destructive) {
                if let node = confirmDelete { withAnimation { ws.deleteForever(node) } }
                confirmDelete = nil
            }
            Button(tr("Отмена"), role: .cancel) { confirmDelete = nil }
        } message: {
            Text(tr("Это нельзя отменить."))
        }
    }

    private func row(_ node: Node) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(node.theme.map { Palette.swatch($0.colorIndex).ink } ?? Color.secondary.opacity(0.3))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayTitle).lineLimit(1)
                Text(daysLeftText(node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation { ws.restore(node) }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(tr("Восстановить"))
            Button {
                confirmDelete = node
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(tr("Удалить навсегда"))
        }
        .swipeActions(edge: .leading) {
            Button(tr("Восстановить")) { withAnimation { ws.restore(node) } }.tint(.accentColor)
        }
        .swipeActions(edge: .trailing) {
            Button(tr("Удалить"), role: .destructive) { confirmDelete = node }
        }
        .contextMenu {
            Button(tr("Восстановить"), systemImage: "arrow.uturn.backward") { ws.restore(node) }
            Button(tr("Удалить навсегда"), systemImage: "trash", role: .destructive) { confirmDelete = node }
        }
    }

    private func daysLeftText(_ node: Node) -> String {
        let days = node.daysLeftInTrash
        return tr("Осталось дней") + ": \(days)"
    }
}

/// Плашка внизу холста после удаления: «Заметка в корзине · Отменить».
struct TrashToast: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text(tr("Заметка в корзине"))
            Button(tr("Отменить")) { ws.undoTrashFromToast() }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
    }
}

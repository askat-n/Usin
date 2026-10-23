import SwiftUI
import SwiftData

struct NoteEditorView: View {
    @Bindable var node: Node
    @Environment(Workspace.self) private var ws
    @Environment(\.modelContext) private var context
    @FocusState private var focus: UUID?
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                TextField("Название", text: $node.title, axis: .vertical)
                    .font(.system(size: 34, weight: .bold))
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onChange(of: node.title) { _, new in
                        guard new.contains("\n") else { return }
                        node.title = new.replacingOccurrences(of: "\n", with: "")
                        focus = node.sortedBlocks.first?.id
                    }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(node.sortedBlocks) { block in
                        BlockRow(block: block, node: node, focus: $focus)
                    }
                }

                addBar
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.editor)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onAppear {
            if node.title.isEmpty { titleFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ThemeMenu(theme: $node.theme, style: .chip)
            Spacer()
            Button {
                ws.showOnCanvas(node)
            } label: {
                Label("На холсте", systemImage: "scope")
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Menu {
                Button("Удалить заметку", systemImage: "trash", role: .destructive) { ws.delete(node) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
    }

    /// Быстрое добавление блоков в конец заметки.
    private var addBar: some View {
        HStack(spacing: 2) {
            ForEach(BlockKind.allCases) { kind in
                Button {
                    let b = node.addBlock(kind, context: context)
                    focusSoon(b.id)
                } label: {
                    Image(systemName: kind.icon)
                        .font(.system(size: 13))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(kind.title)
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.top, 8)
    }

    private func focusSoon(_ id: UUID) {
        DispatchQueue.main.async { focus = id }
    }
}

import SwiftUI
import SwiftData

struct NoteEditorView: View {
    @Bindable var node: Node
    @Environment(Workspace.self) private var ws
    @Environment(\.modelContext) private var context
    @FocusState private var focus: UUID?
    @FocusState private var titleFocused: Bool

    // Перестановка строк за ≡
    @State private var draggingID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var rowFrames: [UUID: CGRect] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                TextField(tr("Название"), text: $node.title, axis: .vertical)
                    .font(.system(size: 34, weight: .bold, design: AppSettings.shared.isTerminal ? .monospaced : .default))
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onChange(of: node.title) { _, new in
                        guard new.contains("\n") else { return }
                        node.title = new.replacingOccurrences(of: "\n", with: "")
                        focus = node.sortedBlocks.first?.id
                    }
                    .onSubmit { focus = node.sortedBlocks.first?.id }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(node.sortedBlocks) { block in
                        let dragging = draggingID == block.id
                        BlockRow(
                            block: block, node: node, focus: $focus,
                            isDragging: dragging,
                            onReorder: { dy in
                                draggingID = block.id
                                dragOffset = dy
                            },
                            onReorderEnd: finishReorder
                        )
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("blocks")) } action: {
                            rowFrames[block.id] = $0
                        }
                        .background {
                            if dragging {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.editor)
                                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                                    .padding(-4)
                            }
                        }
                        .offset(y: dragging ? dragOffset : 0)
                        .zIndex(dragging ? 1 : 0)
                    }
                }
                .coordinateSpace(.named("blocks"))
                .overlay(alignment: .topLeading) {
                    if let y = dropIndicatorY {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                            .padding(.leading, 28)
                            .offset(y: y - 1.5)
                            .allowsHitTesting(false)
                    }
                }

                addBar
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AppSettings.shared.isTerminal ? Term.bg : Color.editor)
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
                Label(tr("На холсте"), systemImage: "scope")
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Menu {
                Button(tr("Удалить заметку"), systemImage: "trash", role: .destructive) { ws.delete(node) }
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

    // MARK: - Reorder

    /// Куда встанет перетаскиваемая строка: индекс среди остальных строк.
    private var dropTarget: (index: Int, others: [NoteBlock])? {
        guard let id = draggingID, let frame = rowFrames[id] else { return nil }
        let center = frame.midY + dragOffset
        let others = node.sortedBlocks.filter { $0.id != id }
        let index = others.filter { (rowFrames[$0.id]?.midY ?? 0) < center }.count
        return (index, others)
    }

    private var dropIndicatorY: CGFloat? {
        guard let id = draggingID, let target = dropTarget,
              let original = node.sortedBlocks.firstIndex(where: { $0.id == id }),
              target.index != original else { return nil }
        if target.index < target.others.count {
            return (rowFrames[target.others[target.index].id]?.minY ?? 0) - 2
        }
        return (target.others.last.flatMap { rowFrames[$0.id]?.maxY } ?? 0) + 2
    }

    private func finishReorder() {
        if let id = draggingID, let target = dropTarget,
           let block = node.blocks.first(where: { $0.id == id }) {
            withAnimation(.snappy) {
                node.moveBlock(block, to: target.index)
                draggingID = nil
                dragOffset = 0
            }
        } else {
            draggingID = nil
            dragOffset = 0
        }
    }

    private func focusSoon(_ id: UUID) {
        DispatchQueue.main.async { focus = id }
    }
}

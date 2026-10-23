import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct BlockRow: View {
    @Bindable var block: NoteBlock
    let node: Node
    var focus: FocusState<UUID?>.Binding
    var isDragging = false
    /// Тянут ≡: смещение пальца по вертикали.
    var onReorder: (CGFloat) -> Void = { _ in }
    var onReorderEnd: () -> Void = {}

    @Environment(\.modelContext) private var context
    @State private var showMenu = false
    @State private var lastReturnAt = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                handle
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if block.kind == .text && block.text == "/" {
                SlashMenu { kind in convert(to: kind) }
                    .padding(.leading, 28)
            }
        }
    }

    // MARK: - Block content

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .text:
            TextField(tr("Пиши… или «/» для блоков"), text: $block.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(3)
                .focused(focus, equals: block.id)
                .padding(.vertical, 3)
                .onChange(of: block.text) { _, new in splitOnReturn(new) }
                .onSubmit { handleReturn() }

        case .heading:
            TextField(tr("Заголовок"), text: $block.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title2.bold())
                .focused(focus, equals: block.id)
                .padding(.top, 10)
                .onChange(of: block.text) { _, new in splitOnReturn(new) }
                .onSubmit { handleReturn() }

        case .checklist:
            HStack(alignment: .top, spacing: 8) {
                Button { block.isChecked.toggle() } label: {
                    Image(systemName: block.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(block.isChecked ? Color.accentColor : Color.secondary)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                TextField(tr("Пункт"), text: $block.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .strikethrough(block.isChecked)
                    .foregroundStyle(block.isChecked ? .secondary : .primary)
                    .focused(focus, equals: block.id)
                    .onChange(of: block.text) { _, new in splitOnReturn(new) }
                    .onSubmit { handleReturn() }
            }
            .padding(.vertical, 3)

        case .image:
            ImageBlock(block: block)

        case .link:
            LinkBlock(block: block, focus: focus) { handleReturn() }

        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 14)
        }
    }

    // MARK: - Handle: тап — меню, потянуть — переставить строку

    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isDragging ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            .frame(width: 22, height: 26)
            .contentShape(Rectangle().inset(by: -4))
            .padding(.top, block.kind == .heading ? 12 : 1)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { v in onReorder(v.translation.height) }
                    .onEnded { _ in onReorderEnd() }
            )
            .onTapGesture { showMenu = true }
            .popover(isPresented: $showMenu) {
                BlockMenu(
                    current: block.kind,
                    canConvert: canConvert(to:),
                    hint: conversionHint,
                    onConvert: { kind in showMenu = false; convert(to: kind) },
                    onAddBelow: { showMenu = false; insert(.text) },
                    onDelete: { showMenu = false; node.remove(block, context: context) }
                )
                .presentationCompactAdaptation(.popover)
            }
            .help(tr("Нажми — меню. Потяни — переставить строку"))
    }

    // MARK: - Conversion

    private var hasText: Bool { !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Превращать можно только так, чтобы содержимое не пропало.
    private func canConvert(to kind: BlockKind) -> Bool {
        if kind == block.kind { return false }
        if block.kind == .image && block.imageData != nil { return false }
        if hasText && (kind == .image || kind == .divider) { return false }
        return true
    }

    private var conversionHint: String? {
        if block.kind == .image && block.imageData != nil {
            return tr("Картинку нельзя превратить в другой блок — иначе она пропадёт")
        }
        if hasText && block.kind != .image && block.kind != .divider {
            return tr("Картинка и разделитель недоступны: в строке есть текст")
        }
        return nil
    }

    private func convert(to kind: BlockKind) {
        if block.text == "/" { block.text = "" }
        guard kind == block.kind || canConvert(to: kind) else { return }
        block.kind = kind
        if kind == .divider {
            insert(.text)
        } else {
            DispatchQueue.main.async { focus.wrappedValue = block.id }
        }
    }

    // MARK: - Enter

    /// Enter приходит либо как перенос строки в тексте, либо как «отправить» (onSubmit) —
    /// в обоих случаях делаем новую строку-блок.
    /// Текст после курсора переезжает в новую строку.
    private func splitOnReturn(_ new: String) {
        guard let r = new.firstIndex(of: "\n") else { return }
        let before = String(new[..<r])
        let after = String(new[new.index(after: r)...]).replacingOccurrences(of: "\n", with: " ")
        block.text = before
        handleReturn(carry: after)
    }

    private func handleReturn(carry: String = "") {
        // Одно нажатие может прийти и переносом, и onSubmit — считаем его один раз.
        guard Date().timeIntervalSince(lastReturnAt) > 0.2 else { return }
        lastReturnAt = Date()
        // Enter на пустом пункте чек-листа — выход из списка.
        if block.kind == .checklist && block.text.isEmpty && carry.isEmpty {
            block.kind = .text
            return
        }
        let next = insert(block.kind == .checklist ? .checklist : .text)
        next.text = carry
    }

    @discardableResult
    private func insert(_ kind: BlockKind) -> NoteBlock {
        let new = node.addBlock(kind, after: block, context: context)
        DispatchQueue.main.async { focus.wrappedValue = new.id }
        return new
    }
}

// MARK: - Block menu

struct BlockMenu: View {
    let current: BlockKind
    let canConvert: (BlockKind) -> Bool
    let hint: String?
    let onConvert: (BlockKind) -> Void
    let onAddBelow: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Превратить в"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(BlockKind.allCases) { kind in
                row(kind.title, icon: kind.icon, checked: kind == current,
                    enabled: kind == current || canConvert(kind)) { onConvert(kind) }
            }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            Divider().padding(.vertical, 4)
            row(tr("Добавить строку ниже"), icon: "plus", action: onAddBelow)
            row(tr("Удалить"), icon: "trash", destructive: true, action: onDelete)
        }
        .font(.callout)
        .padding(.bottom, 6)
        .frame(width: 260)
    }

    private func row(_ title: String, icon: String, checked: Bool = false, enabled: Bool = true,
                     destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                Spacer()
                if checked { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - Slash menu

struct SlashMenu: View {
    let onPick: (BlockKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(BlockKind.allCases.filter { $0 != .text }) { kind in
                Button { onPick(kind) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: kind.icon).frame(width: 20)
                        Text(kind.title)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

// MARK: - Image

struct ImageBlock: View {
    @Bindable var block: NoteBlock
    @State private var pickerItem: PhotosPickerItem?
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let data = block.imageData, let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contextMenu {
                        Button(tr("Заменить из Фото"), systemImage: "photo") { block.setImage(nil) }
                    }
            } else {
                placeholder
            }
        }
        .padding(.vertical, 6)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    block.setImage(data)
                }
                pickerItem = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { load(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            load(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var placeholder: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(tr("Из Фото"), systemImage: "photo.on.rectangle")
            }
            Button { importing = true } label: {
                Label(tr("Из файла"), systemImage: "folder")
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(0.15),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .overlay(alignment: .bottom) {
            Text(tr("или перетащи картинку сюда"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), PlatformImage(data: data) != nil {
            block.setImage(data)
        }
    }
}

// MARK: - Link

struct LinkBlock: View {
    @Bindable var block: NoteBlock
    var focus: FocusState<UUID?>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            TextField("https://…", text: $block.text)
                .textFieldStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .focused(focus, equals: block.id)
                .onSubmit(onSubmit)
            if let url = block.url {
                Link(destination: url) {
                    Label(url.host() ?? tr("Открыть"), systemImage: "arrow.up.right")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .help(tr("Открыть ссылку"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.vertical, 3)
    }
}

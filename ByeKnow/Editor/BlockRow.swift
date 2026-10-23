import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct BlockRow: View {
    @Bindable var block: NoteBlock
    let node: Node
    var focus: FocusState<UUID?>.Binding

    @Environment(\.modelContext) private var context

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
            TextField("Пиши… или «/» для блоков", text: $block.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(3)
                .focused(focus, equals: block.id)
                .padding(.vertical, 3)

        case .heading:
            TextField("Заголовок", text: $block.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title2.bold())
                .focused(focus, equals: block.id)
                .padding(.top, 10)
                .onChange(of: block.text) { _, new in
                    guard new.contains("\n") else { return }
                    block.text = new.replacingOccurrences(of: "\n", with: "")
                    insert(.text)
                }

        case .checklist:
            HStack(alignment: .top, spacing: 8) {
                Button { block.isChecked.toggle() } label: {
                    Image(systemName: block.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(block.isChecked ? Color.accentColor : Color.secondary)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                TextField("Пункт", text: $block.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .strikethrough(block.isChecked)
                    .foregroundStyle(block.isChecked ? .secondary : .primary)
                    .focused(focus, equals: block.id)
                    .onChange(of: block.text) { _, new in
                        guard new.contains("\n") else { return }
                        let clean = new.replacingOccurrences(of: "\n", with: "")
                        block.text = clean
                        if clean.isEmpty {
                            block.kind = .text // Enter на пустом пункте — выход из списка
                        } else {
                            insert(.checklist)
                        }
                    }
            }
            .padding(.vertical, 3)

        case .image:
            ImageBlock(block: block)

        case .link:
            LinkBlock(block: block, focus: focus)

        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 14)
        }
    }

    // MARK: - Handle menu

    private var handle: some View {
        Menu {
            Section("Превратить в") {
                ForEach(BlockKind.allCases) { kind in
                    Button(kind.title, systemImage: kind.icon) { convert(to: kind) }
                }
            }
            Button("Добавить блок ниже", systemImage: "plus") { insert(.text) }
            Button("Выше", systemImage: "arrow.up") { node.move(block, by: -1) }
            Button("Ниже", systemImage: "arrow.down") { node.move(block, by: 1) }
            Divider()
            Button("Удалить", systemImage: "trash", role: .destructive) { node.remove(block, context: context) }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.quaternary)
                .frame(width: 22, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.top, block.kind == .heading ? 12 : 1)
    }

    // MARK: - Actions

    private func convert(to kind: BlockKind) {
        if block.text == "/" { block.text = "" }
        block.kind = kind
        if kind == .divider {
            insert(.text)
        } else {
            DispatchQueue.main.async { focus.wrappedValue = block.id }
        }
    }

    private func insert(_ kind: BlockKind) {
        let new = node.addBlock(kind, after: block, context: context)
        DispatchQueue.main.async { focus.wrappedValue = new.id }
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
                        Button("Заменить из Фото", systemImage: "photo") { block.imageData = nil }
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
                    block.imageData = data
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
                Label("Из Фото", systemImage: "photo.on.rectangle")
            }
            Button { importing = true } label: {
                Label("Из файла", systemImage: "folder")
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
            Text("или перетащи картинку сюда")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), PlatformImage(data: data) != nil {
            block.imageData = data
        }
    }
}

// MARK: - Link

struct LinkBlock: View {
    @Bindable var block: NoteBlock
    var focus: FocusState<UUID?>.Binding

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
            if let url = block.url {
                Link(destination: url) {
                    Label(url.host() ?? "Открыть", systemImage: "arrow.up.right")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .help("Открыть ссылку")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.vertical, 3)
    }
}

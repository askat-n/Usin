import SwiftUI
import SwiftData

/// Общее состояние приложения: камера холста, выделение, фильтр, вкладки.
@Observable
final class Workspace {
    enum Selection: Equatable {
        case empty
        case node(UUID)
        case connection(UUID)
    }

    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 3

    let context: ModelContext

    // Камера холста
    var offset: CGSize = .zero
    var scale: CGFloat = 1
    var canvasSize: CGSize = .zero
    var canvasFrame: CGRect = .zero

    var selection: Selection = .empty
    var editingTitleID: UUID?
    var filterThemeID: UUID?

    // Вкладки: nil = холст
    var openTabs: [UUID] = []
    var activeTab: UUID?

    var showAllNotes = false
    var showSettings = false

    init(context: ModelContext) {
        self.context = context
        ensureRoot()
        restoreTabs()
        centerOnRoot()
    }

    // MARK: - Lookup

    func node(_ id: UUID) -> Node? {
        var d = FetchDescriptor<Node>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func theme(_ id: UUID) -> Theme? {
        var d = FetchDescriptor<Theme>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private var allConnections: [Connection] {
        (try? context.fetch(FetchDescriptor<Connection>())) ?? []
    }

    // MARK: - Selection

    func select(_ s: Selection) {
        if s != .node(editingTitleID ?? UUID()) { editingTitleID = nil }
        selection = s
    }

    func startRenaming(_ node: Node) {
        selection = .node(node.id)
        editingTitleID = node.id
    }

    // MARK: - Nodes

    @discardableResult
    func createNode(at point: CGPoint, theme: Theme? = nil, editTitle: Bool = true) -> Node {
        let node = Node(position: point)
        node.shape = AppSettings.shared.defaultShape
        if node.shape == .sticker { node.fillIndex = 3 }
        context.insert(node)
        node.theme = theme ?? filterThemeID.flatMap { self.theme($0) }
        node.addBlock(.text, context: context)
        select(.node(node.id))
        if editTitle { editingTitleID = node.id }
        return node
    }

    /// Новая заметка рядом с центром экрана.
    func createNodeAtViewCenter() {
        activeTab = nil
        createNode(at: viewCenterPoint())
    }

    /// Новая заметка сразу во вкладке (и на холсте).
    func newNoteTab() {
        let node = createNode(at: viewCenterPoint(), editTitle: false)
        open(node)
    }

    private func viewCenterPoint() -> CGPoint {
        CGPoint(
            x: -offset.width / scale + .random(in: -120...120),
            y: -offset.height / scale + .random(in: 130...200)
        )
    }

    func delete(_ node: Node) {
        guard !node.isRoot else { return }
        let id = node.id
        for c in allConnections where c.fromID == id || c.toID == id {
            context.delete(c)
        }
        close(tab: id)
        if editingTitleID == id { editingTitleID = nil }
        selection = .empty
        context.delete(node)
    }

    func deleteSelection() {
        guard activeTab == nil, editingTitleID == nil else { return }
        switch selection {
        case .node(let id):
            if let n = node(id) { delete(n) }
        case .connection(let id):
            if let c = allConnections.first(where: { $0.id == id }) {
                context.delete(c)
                selection = .empty
            }
        case .empty:
            break
        }
    }

    // MARK: - Connections

    func connect(from: UUID, to: UUID) {
        guard from != to else { return }
        let exists = allConnections.contains {
            ($0.fromID == from && $0.toID == to) || ($0.fromID == to && $0.toID == from)
        }
        guard !exists else { return }
        context.insert(Connection(from: from, to: to))
    }

    // MARK: - Themes

    @discardableResult
    func createTheme(named name: String) -> Theme {
        let count = (try? context.fetchCount(FetchDescriptor<Theme>())) ?? 0
        let theme = Theme(name: name, colorIndex: count % 8 + 1, order: count)
        context.insert(theme)
        return theme
    }

    func delete(_ theme: Theme) {
        if filterThemeID == theme.id { filterThemeID = nil }
        context.delete(theme)
    }

    // MARK: - Tabs

    func open(_ node: Node) {
        guard !node.isRoot else { return }
        if !openTabs.contains(node.id) { openTabs.append(node.id) }
        editingTitleID = nil
        activeTab = node.id
        saveTabs()
    }

    func close(tab id: UUID) {
        guard let i = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: i)
        if activeTab == id {
            activeTab = openTabs.indices.contains(i) ? openTabs[i] : openTabs.last
        }
        saveTabs()
    }

    /// 0 = холст, 1… = вкладки.
    func selectTab(at index: Int) {
        if index == 0 { activeTab = nil }
        else if openTabs.indices.contains(index - 1) { activeTab = openTabs[index - 1] }
    }

    func cycleTab(_ step: Int) {
        let all: [UUID?] = [nil] + openTabs.map { Optional($0) }
        let current = all.firstIndex(of: activeTab) ?? 0
        activeTab = all[(current + step + all.count) % all.count]
    }

    func showOnCanvas(_ node: Node) {
        activeTab = nil
        select(.node(node.id))
        withAnimation(.snappy) {
            offset = CGSize(width: -node.x * scale, height: -node.y * scale)
        }
    }

    private func saveTabs() {
        UserDefaults.standard.set(openTabs.map(\.uuidString), forKey: "openTabs")
    }

    private func restoreTabs() {
        let ids = (UserDefaults.standard.stringArray(forKey: "openTabs") ?? []).compactMap(UUID.init)
        openTabs = ids.filter { node($0) != nil }
    }

    // MARK: - Camera

    /// Вернуться к сфере ByeKnow — где бы она ни стояла.
    func goHome() {
        withAnimation(.snappy) { centerOnRoot() }
    }

    private func centerOnRoot() {
        var d = FetchDescriptor<Node>(predicate: #Predicate { $0.isRoot == true })
        d.fetchLimit = 1
        let root = try? context.fetch(d).first
        scale = 1
        offset = CGSize(width: -(root?.x ?? 0), height: -(root?.y ?? 0))
    }

    func resetZoom() {
        zoom(by: 1 / scale)
    }

    /// Масштаб вокруг точки экрана (по умолчанию — центр холста).
    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let a = anchor ?? center
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        let wx = (a.x - center.x - offset.width) / scale
        let wy = (a.y - center.y - offset.height) / scale
        offset = CGSize(width: a.x - center.x - wx * newScale, height: a.y - center.y - wy * newScale)
        scale = newScale
    }

    // MARK: - Setup

    private func ensureRoot() {
        let d = FetchDescriptor<Node>(predicate: #Predicate { $0.isRoot == true })
        let roots = ((try? context.fetch(d)) ?? []).sorted { $0.createdAt < $1.createdAt }
        guard let root = roots.first else {
            let root = Node(position: .zero)
            root.id = Node.rootID
            root.isRoot = true
            root.title = "ByeKnow"
            root.shape = .circle
            root.fillIndex = 6
            context.insert(root)
            try? context.save()
            return
        }
        // Старые версии давали сфере случайный id — переводим на общий, стрелки тоже.
        for extra in roots.dropFirst() { context.delete(extra) }
        if root.id != Node.rootID {
            let old = root.id
            root.id = Node.rootID
            for c in (try? context.fetch(FetchDescriptor<Connection>())) ?? [] {
                if c.fromID == old { c.fromID = Node.rootID }
                if c.toID == old { c.toID = Node.rootID }
            }
        }
        if context.hasChanges { try? context.save() }
    }
}

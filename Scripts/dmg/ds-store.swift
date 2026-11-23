// Пишет .DS_Store для окна установочного образа: Usin слева, «Программы» справа, фон со стрелкой.
// Так Finder показывает окно «как в других приложениях», а управлять самим Finder не нужно.
//   swift Scripts/dmg/ds-store.swift /Volumes/Usin-123 Usin.app
// Образ должен быть подключён: ссылке на фон нужны номера файлов и дата создания тома.
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: ds-store.swift <volume> <App.app>"); exit(2) }
let volume = URL(fileURLWithPath: args[1])
let appName = args[2]
let backgroundRel = ".background/background.png"
let background = volume.appendingPathComponent(backgroundRel)

// Окно и значки: фон 600×400, центры значков — как на фоне (стрелка между ними).
let window = (x: 200, y: 120, w: 600, h: 400)
let iconSize = 128.0
let positions: [String: (Int, Int)] = [appName: (150, 200), "Applications": (450, 200)]

// MARK: - Байты

struct Bytes {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func raw(_ d: Data) { data.append(d) }
    mutating func ascii(_ s: String) { data.append(s.data(using: .ascii)!) }
    mutating func pascal(_ s: String, field: Int) {
        let d = Data(s.utf8.prefix(field - 1))
        u8(UInt8(d.count)); raw(d); raw(Data(count: field - 1 - d.count))
    }
    mutating func utf16(_ s: String) { for c in s.utf16 { u16(c) } }
    mutating func pad(to n: Int) { if data.count < n { data.append(Data(count: n - data.count)) } }
}

// MARK: - Ссылка на фон (старая alias-запись: её до сих пор читает icvp) и закладка (pBBk)

let hfsEpoch = 2_082_844_800.0
func hfsDate(_ d: Date) -> UInt32 { UInt32(max(0, d.timeIntervalSince1970 + hfsEpoch)) }
func cnid(_ url: URL) -> UInt32 {
    let attrs = try! FileManager.default.attributesOfItem(atPath: url.path)
    return UInt32(truncatingIfNeeded: (attrs[.systemFileNumber] as! NSNumber).uint64Value)
}

let volValues = try! volume.resourceValues(forKeys: [.volumeNameKey, .volumeCreationDateKey])
let volName = volValues.volumeName!
let folder = background.deletingLastPathComponent()
let bgCreated = (try! FileManager.default.attributesOfItem(atPath: background.path))[.creationDate] as! Date

func alias() -> Data {
    var b = Bytes()
    b.raw(Data(count: 4)); b.u16(0); b.u16(2)                   // приложение, длина (позже), версия 2
    b.u16(0)                                                     // файл
    b.pascal(volName, field: 28)
    b.u32(hfsDate(volValues.volumeCreationDate!))
    b.ascii("H+"); b.u16(5)                                      // HFS+, съёмный диск
    b.u32(cnid(folder))
    b.pascal(background.lastPathComponent, field: 64)
    b.u32(cnid(background)); b.u32(hfsDate(bgCreated))
    b.raw(Data(count: 8))                                        // тип и создатель
    b.i16(-1); b.i16(-1); b.u32(0); b.raw(Data(count: 2)); b.raw(Data(count: 10))
    func tag(_ t: Int16, _ d: Data) {
        b.i16(t); b.u16(UInt16(d.count)); b.raw(d); if d.count % 2 == 1 { b.u8(0) }
    }
    func uni(_ s: String) -> Data { var x = Bytes(); x.u16(UInt16(s.utf16.count)); x.utf16(s); return x.data }
    tag(0, Data(folder.lastPathComponent.utf8))
    var path = Bytes(); path.u32(cnid(folder)); tag(1, path.data)
    tag(2, Data("\(volName):\(backgroundRel.replacingOccurrences(of: "/", with: ":"))".utf8))
    tag(14, uni(background.lastPathComponent))
    tag(15, uni(volName))
    tag(18, Data("/\(backgroundRel)".utf8))
    tag(19, Data("/Volumes/\(volName)".utf8))   // там образ окажется у пользователя
    b.i16(-1); b.u16(0)
    var data = b.data
    let len = UInt16(data.count).bigEndian
    withUnsafeBytes(of: len) { data.replaceSubrange(4..<6, with: $0) }
    return data
}

func plist(_ object: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

let bwsp = plist([
    "ContainerShowSidebar": false, "PreviewPaneVisibility": false, "ShowPathbar": false,
    "ShowSidebar": false, "ShowStatusBar": false, "ShowTabView": false, "ShowToolbar": false,
    "SidebarWidth": 0, "WindowBounds": "{{\(window.x), \(window.y)}, {\(window.w), \(window.h)}}",
])
let icvp = plist([
    "arrangeBy": "none", "backgroundColorBlue": 1.0, "backgroundColorGreen": 1.0, "backgroundColorRed": 1.0,
    "backgroundImageAlias": alias(), "backgroundType": 2, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
    "gridSpacing": 100.0, "iconSize": iconSize, "labelOnBottom": true, "scrollPositionX": 0.0,
    "scrollPositionY": 0.0, "showIconPreview": true, "showItemInfo": false, "textSize": 13.0,
    "viewOptionsVersion": 1,
])
let bookmark = try! background.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

// MARK: - Записи

enum Value { case blob(Data), long(UInt32), type(String) }
var records: [(name: String, code: String, value: Value)] = [
    (".", "bwsp", .blob(bwsp)), (".", "icvp", .blob(icvp)), (".", "pBBk", .blob(bookmark)),
    (".", "vSrn", .long(1)), (".", "icvl", .type("icnv")),
]
for (name, p) in positions {
    var b = Bytes(); b.u32(UInt32(p.0)); b.u32(UInt32(p.1)); b.u32(0xFFFF_FFFF); b.u32(0xFFFF_0000)
    records.append((name, "Iloc", .blob(b.data)))
}
records.sort { ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code) }

var leaf = Bytes()
leaf.u32(0); leaf.u32(UInt32(records.count))
for r in records {
    leaf.u32(UInt32(r.name.utf16.count)); leaf.utf16(r.name); leaf.ascii(r.code)
    switch r.value {
    case .blob(let d): leaf.ascii("blob"); leaf.u32(UInt32(d.count)); leaf.raw(d)
    case .long(let v): leaf.ascii("long"); leaf.u32(v)
    case .type(let t): leaf.ascii("type"); leaf.ascii(t)
    }
}
precondition(leaf.data.count <= 4096, "записи не помещаются в один узел")

// MARK: - Файл: «buddy»-распределитель блоков (как у Finder)

var free: [[UInt32]] = Array(repeating: [], count: 32)
free[31] = [0]
func allocate(_ size: Int) -> (offset: UInt32, width: UInt32) {
    var w = 5
    while (1 << w) < size { w += 1 }
    var k = w
    while free[k].isEmpty { k += 1 }
    let off = free[k].removeFirst()
    while k > w {
        k -= 1
        free[k].append(off + (1 << k)); free[k].sort()
    }
    return (off, UInt32(w))
}

_ = allocate(32)                         // заголовок файла
let info = allocate(2048)                // блок 0 — таблица блоков
let dsdb = allocate(32)                  // блок 1 — шапка дерева
let node = allocate(4096)                // блок 2 — единственный лист
let addresses = [info, dsdb, node].map { $0.offset | $0.width }

var infoBlock = Bytes()
infoBlock.u32(UInt32(addresses.count)); infoBlock.u32(0)
for a in addresses { infoBlock.u32(a) }
for _ in addresses.count..<256 { infoBlock.u32(0) }
infoBlock.u32(1); infoBlock.u8(4); infoBlock.ascii("DSDB"); infoBlock.u32(1)
for list in free { infoBlock.u32(UInt32(list.count)); for o in list { infoBlock.u32(o) } }
precondition(infoBlock.data.count <= 2048)

var dsdbBlock = Bytes()
dsdbBlock.u32(2); dsdbBlock.u32(0); dsdbBlock.u32(UInt32(records.count)); dsdbBlock.u32(1); dsdbBlock.u32(0x1000)

var file = Bytes()
file.u32(1); file.ascii("Bud1"); file.u32(info.offset); file.u32(2048); file.u32(info.offset)
file.raw(Data([0x00, 0x00, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0B, 0x00, 0x00, 0x00, 0x00]))
func put(_ block: Bytes, at offset: UInt32, size: Int) {
    file.pad(to: Int(offset) + 4)
    precondition(file.data.count == Int(offset) + 4)
    file.raw(block.data); file.pad(to: Int(offset) + 4 + size)
}
for (block, at, size) in [(infoBlock, info.offset, 2048), (dsdbBlock, dsdb.offset, 32), (leaf, node.offset, 4096)]
    .sorted(by: { $0.1 < $1.1 }) {
    put(block, at: at, size: size)
}
try! file.data.write(to: volume.appendingPathComponent(".DS_Store"))
print("DS_Store: \(records.count) записей")

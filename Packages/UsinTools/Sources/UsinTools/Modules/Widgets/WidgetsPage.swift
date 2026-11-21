import SwiftUI

/// Страница «Виджеты» в настройках: что стоит на рабочем столе и что можно добавить.
struct WidgetsPage: View {
    @ObservedObject private var widgets = Coordinator.shared.widgets

    private static let zones = [
        "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Moscow", "Europe/Istanbul", "Asia/Dubai",
        "Asia/Almaty", "Asia/Bishkek", "Asia/Tashkent", "Asia/Kolkata", "Asia/Bangkok", "Asia/Shanghai",
        "Asia/Seoul", "Asia/Tokyo", "Australia/Sydney", "America/New_York", "America/Chicago",
        "America/Denver", "America/Los_Angeles", "America/Sao_Paulo",
    ]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: "square.grid.2x2.fill", tint: .blue, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Виджеты на рабочем столе").font(.headline)
                        Text("Живые: цифры обновляются каждую секунду. Перетаскивайте за любое место, правый клик — размер и удаление.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $widgets.visible).labelsHidden().toggleStyle(.switch)
                }
            }

            if !widgets.widgets.isEmpty {
                Section("На рабочем столе") {
                    ForEach(widgets.widgets) { widget in
                        HStack(spacing: 10) {
                            IconTile(symbol: widget.kind.symbol, tint: widget.kind.tint, size: 26)
                            Text(verbatim: widget.kind.title)
                            Spacer()
                            if widget.kind.sizes.count > 1 {
                                Picker("", selection: Binding(get: { widget.size }, set: { widgets.resize(widget.id, to: $0) })) {
                                    ForEach(widget.kind.sizes) { Text(verbatim: $0.title).tag($0) }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                            Button {
                                widgets.remove(widget.id)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help(Text("Удалить виджет"))
                        }
                    }
                }
            }

            Section("Добавить") {
                ForEach(WidgetKind.allCases) { kind in
                    HStack(spacing: 10) {
                        IconTile(symbol: kind.symbol, tint: kind.tint, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: kind.title)
                            Text(verbatim: kind.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if kind.sizes.count > 1 {
                            Menu("Добавить") {
                                ForEach(kind.sizes) { size in
                                    Button(size.title) { widgets.add(kind, size: size) }
                                }
                            }
                            .fixedSize()
                        } else {
                            Button("Добавить") { widgets.add(kind) }
                        }
                    }
                }
            }

            Section("Часы") {
                ForEach(0..<2, id: \.self) { index in
                    Picker(index == 0 ? L("Второй город") : L("Третий город"), selection: Binding(
                        get: { index < widgets.clockZones.count ? widgets.clockZones[index] : "" },
                        set: { value in
                            var zones = widgets.clockZones
                            while zones.count <= index { zones.append("") }
                            zones[index] = value
                            widgets.clockZones = zones.filter { !$0.isEmpty }
                        }
                    )) {
                        Text("Нет").tag("")
                        ForEach(Self.zones, id: \.self) { id in
                            Text(verbatim: TimeZone(identifier: id).map(cityName) ?? id).tag(id)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

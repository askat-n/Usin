import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Цвет, который сам меняется для светлой и тёмной темы.
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #endif
    }

    static let canvas = Color(light: 0xF6F6F3, dark: 0x19191B)
    static let gridDot = Color(light: 0xD8D8D2, dark: 0x34343A)
    static let editor = Color(light: 0xFFFFFF, dark: 0x1E1E21)
}

struct Swatch {
    let name: String
    /// Мягкий цвет — для заливки фигур.
    let fill: Color
    /// Насыщенный цвет — для текста, стрелок, тем.
    let ink: Color
}

enum Palette {
    static let swatches: [Swatch] = [
        Swatch(name: "Обычный", fill: Color(light: 0xFFFFFF, dark: 0x2A2A2E), ink: .primary),
        Swatch(name: "Красный", fill: Color(light: 0xFDE4E2, dark: 0x4B2828), ink: Color(light: 0xD92D20, dark: 0xFF8A80)),
        Swatch(name: "Оранжевый", fill: Color(light: 0xFDEBD8, dark: 0x4A3320), ink: Color(light: 0xC4560A, dark: 0xFFB06B)),
        Swatch(name: "Жёлтый", fill: Color(light: 0xFBF1BF, dark: 0x4A4220), ink: Color(light: 0x9A7400, dark: 0xF5D86B)),
        Swatch(name: "Зелёный", fill: Color(light: 0xDDF3E4, dark: 0x1F3D2A), ink: Color(light: 0x1E8E4E, dark: 0x7FD8A0)),
        Swatch(name: "Бирюзовый", fill: Color(light: 0xD8F1F1, dark: 0x1D3B3D), ink: Color(light: 0x0E7C86, dark: 0x72D3DA)),
        Swatch(name: "Синий", fill: Color(light: 0xDCE8FD, dark: 0x1F2E4D), ink: Color(light: 0x2563EB, dark: 0x8AB4FF)),
        Swatch(name: "Фиолетовый", fill: Color(light: 0xEAE1FB, dark: 0x33284D), ink: Color(light: 0x7C3AED, dark: 0xC4A5FF)),
        Swatch(name: "Розовый", fill: Color(light: 0xFBE0EE, dark: 0x4A2338), ink: Color(light: 0xC2185B, dark: 0xFF9CC8)),
    ]

    static func swatch(_ index: Int) -> Swatch {
        let i = swatches.indices.contains(index) ? index : 0
        // В «Терминале» — яркие цвета терминала (палитра Dracula), чтобы их легко различать.
        if AppSettings.shared.isTerminal { return terminalSwatches[i] }
        return swatches[i]
    }

    /// Порядок совпадает с `swatches`: обычный, красный, оранжевый, жёлтый, зелёный, бирюзовый, синий, фиолетовый, розовый.
    static let terminalInks: [Color] = [
        Color(hex: 0x4ADE80), Color(hex: 0xFF5555), Color(hex: 0xFFB86C), Color(hex: 0xF1FA8C), Color(hex: 0x50FA7B),
        Color(hex: 0x8BE9FD), Color(hex: 0x6CA8FF), Color(hex: 0xBD93F9), Color(hex: 0xFF79C6),
    ]

    private static let terminalSwatches: [Swatch] = swatches.indices.map { i in
        Swatch(name: swatches[i].name,
               fill: i == 0 ? Color(hex: 0x070C07) : terminalInks[i].opacity(0.16),
               ink: terminalInks[i])
    }
}

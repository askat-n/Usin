import SwiftUI
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Мост к Core Animation: SwiftUI только описывает слои, а крутит анимации
/// системный процесс отрисовки — приложение на это почти не тратит процессор.
/// Вызов `render` — при каждом обновлении SwiftUI и при смене размера.
struct LayerHost {
    /// (корневой слой, размер, масштаб экрана, окружение SwiftUI — для цветов)
    let render: (CALayer, CGSize, CGFloat, EnvironmentValues) -> Void
}

#if os(macOS)
final class LayerHostView: NSView {
    var renderer: ((CALayer, CGSize, CGFloat, EnvironmentValues) -> Void)?
    var environment = EnvironmentValues()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        draw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        draw()
    }

    func draw() {
        guard let renderer, let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer(layer, bounds.size, window?.backingScaleFactor ?? 2, environment)
        CATransaction.commit()
    }
}

extension LayerHost: NSViewRepresentable {
    func makeNSView(context: Context) -> LayerHostView { LayerHostView() }

    func updateNSView(_ view: LayerHostView, context: Context) {
        view.renderer = render
        view.environment = context.environment
        view.draw()
    }
}
#else
final class LayerHostView: UIView {
    var renderer: ((CALayer, CGSize, CGFloat, EnvironmentValues) -> Void)?
    var environment = EnvironmentValues()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        draw()
    }

    func draw() {
        guard let renderer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer(layer, bounds.size, traitCollection.displayScale, environment)
        CATransaction.commit()
    }
}

extension LayerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> LayerHostView { LayerHostView() }

    func updateUIView(_ view: LayerHostView, context: Context) {
        view.renderer = render
        view.environment = context.environment
        view.draw()
    }
}
#endif

// MARK: - Helpers

extension CALayer {
    /// Дочерний слой с именем `name` — создаётся один раз, потом переиспользуется
    /// (чтобы не сбрасывать уже идущие анимации).
    func sublayer<L: CALayer>(_ name: String, scale: CGFloat, make: () -> L) -> L {
        if let existing = sublayers?.first(where: { $0.name == name }) as? L { return existing }
        let layer = make()
        layer.name = name
        layer.contentsScale = scale
        addSublayer(layer)
        return layer
    }

    /// Удалить дочерние слои, которых больше нет в `keep`.
    func removeSublayers(except keep: Set<String>) {
        for layer in sublayers ?? [] where !keep.contains(layer.name ?? "") {
            layer.removeFromSuperlayer()
        }
    }

    /// Бесконечная анимация: добавить, если включено и её ещё нет; убрать, если выключено.
    func loop(_ key: String, enabled: Bool, make: () -> CAAnimation) {
        if enabled {
            if animation(forKey: key) == nil {
                let animation = make()
                animation.repeatCount = .infinity
                animation.isRemovedOnCompletion = false
                add(animation, forKey: key)
            }
        } else {
            removeAnimation(forKey: key)
        }
    }
}

func basic(_ keyPath: String, from: Any?, to: Any?, duration: Double, autoreverses: Bool = true,
           timing: CAMediaTimingFunctionName = .easeInEaseOut, begin: Double = 0) -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: keyPath)
    a.fromValue = from
    a.toValue = to
    a.duration = duration
    a.autoreverses = autoreverses
    a.timingFunction = CAMediaTimingFunction(name: timing)
    if begin != 0 { a.beginTime = CACurrentMediaTime() + begin; a.fillMode = .backwards }
    return a
}

extension Color {
    func cg(_ env: EnvironmentValues) -> CGColor { resolve(in: env).cgColor }
}

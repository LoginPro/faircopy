import AppKit
import Combine
import SwiftUI

/// Плавающая стеклянная панель, которая не активирует наше приложение: исходное окно
/// (Telegram и т. п.) остаётся активным, и ⌘V потом попадёт куда нужно.
final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Где держать окно: под строкой текста (верхний край фиксирован) или над ней (нижний).
    private enum Anchor { case top(CGFloat), bottom(CGFloat) }

    private let model: EditorModel
    private var host: NSHostingController<AnyView>!
    private var changes: AnyCancellable?
    private var anchor: Anchor = .top(0)
    private var screenFrame: NSRect = .zero

    static let width: CGFloat = 460
    /// Прозрачные поля вокруг стекла под собственную тень. Системная тень окна считается
    /// по прямоугольнику с системным скруглением и даёт второй контур вокруг стекла.
    static let margin: CGFloat = 28

    init(model: EditorModel) {
        self.model = model
        // без рамки и заголовка: форму, стекло и тень рисует сам SwiftUI-контент
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow // мягкое появление вместо мгновенного
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        host = NSHostingController(rootView: AnyView(EditorView(model: model)))
        host.sizingOptions = []
        host.safeAreaRegions = []
        contentViewController = host
        // фон хост-вью прозрачный: видна только стеклянная форма, без прямоугольной подложки
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        // SwiftUI-содержимое растёт во время стрима — подгоняем окно, держа якорный край на месте
        changes = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }
    }

    /// `target` — строка с текстовым курсором (если приложение её отдаёт) или точка мыши.
    func show(at target: NSRect) {
        let probe = NSPoint(x: target.midX, y: target.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main!
        screenFrame = screen.visibleFrame
        // ~470 pt занимают шапка, режимы, стили, оригинал, подсказка и кнопки — остальное отдаём результату
        model.maxResultHeight = max(140, screenFrame.height - 16 - 470)

        // под строкой, если там хватает места на типичное окно, иначе над ней (как поле ввода
        // мессенджера внизу экрана — окно встаёт над ним и не закрывает текст)
        let roomBelow = target.minY - screenFrame.minY
        anchor = roomBelow >= 420 ? .top(target.minY - 10) : .bottom(target.maxY + 10)
        let m = Self.margin
        let x = min(max(target.minX - 24, screenFrame.minX + 8), screenFrame.maxX - Self.width - 8) - m
        setFrameOrigin(NSPoint(x: x, y: frame.minY))
        fit()
        makeKeyAndOrderFront(nil)
    }

    private func fit() {
        guard host != nil else { return }
        let m = Self.margin
        let size = host.sizeThatFits(in: NSSize(width: Self.width + 2 * m, height: 10_000))
        let h = min(size.height, screenFrame.height - 16 + 2 * m)
        // якорь задаёт край стекла, а у окна вокруг стекла ещё поля под тень
        var top: CGFloat
        switch anchor {
        case .top(let y): top = y + m
        case .bottom(let y): top = y - m + h
        }
        // не влезает — сдвигаем внутрь экрана, а не обрезаем (раньше срезались кнопки)
        top = min(max(top, screenFrame.minY + 8 + h - m), screenFrame.maxY - 8 + m)
        let frame = NSRect(x: self.frame.minX, y: top - h, width: size.width, height: h)
        if frame != self.frame { setFrame(frame, display: true) }
    }
}

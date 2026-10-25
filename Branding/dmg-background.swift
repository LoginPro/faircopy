// Фон окна установочного DMG: тетрадный лист в клетку (как на иконке), поля
// и золотая стрелка «перетащи в Программы». Запуск: swift Branding/dmg-background.swift <папка>
// Рисует background.png (660×420) и background@2x.png — dmgbuild склеит их в один HiDPI-фон.
import AppKit

let size = CGSize(width: 660, height: 420)
let ink = NSColor(srgbRed: 0x22 / 255, green: 0x26 / 255, blue: 0x7A / 255, alpha: 1)
let margin = NSColor(srgbRed: 1, green: 0x5C / 255, blue: 0x6C / 255, alpha: 0.55)
let goldTop = NSColor(srgbRed: 1, green: 0xE5 / 255, blue: 0x8A / 255, alpha: 1)
let goldBottom = NSColor(srgbRed: 1, green: 0xB5 / 255, blue: 0x47 / 255, alpha: 1)

func render(scale: CGFloat, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // AppKit рисует снизу вверх; переворачиваем, чтобы координаты совпадали с Finder (y сверху)
    let cg = NSGraphicsContext.current!.cgContext
    cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    // бумага
    NSGradient(starting: .white, ending: NSColor(srgbRed: 0xE4 / 255, green: 0xE8 / 255, blue: 1, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: 90)
    // клетка
    ink.withAlphaComponent(0.07).setStroke()
    let grid = NSBezierPath(); grid.lineWidth = 1
    for x in stride(from: 22.0, to: size.width, by: 22) { grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: size.height)) }
    for y in stride(from: 22.0, to: size.height, by: 22) { grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: size.width, y: y)) }
    grid.stroke()
    // поля тетради
    margin.setFill()
    NSRect(x: size.width - 66, y: 0, width: 2, height: size.height).fill()

    // заголовок
    func text(_ s: String, _ font: NSFont, _ color: NSColor, y: CGFloat, kern: CGFloat = 0) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: kern])
        a.draw(in: NSRect(x: 0, y: y, width: size.width - 66, height: 60))
    }
    let rounded = NSFont.systemFont(ofSize: 34, weight: .bold).fontDescriptor.withDesign(.rounded)!
    text("FairCopy", NSFont(descriptor: rounded, size: 34)!, ink, y: 34, kern: -0.5)
    text("A clean copy of every message. Offline.", .systemFont(ofSize: 14, weight: .medium), ink.withAlphaComponent(0.6), y: 80)

    // стрелка между иконками (иконки: центры в 165 и 430 по x, 225 по y)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 240, y: 218))
    arrow.curve(to: NSPoint(x: 350, y: 218), controlPoint1: NSPoint(x: 275, y: 192), controlPoint2: NSPoint(x: 315, y: 192))
    arrow.lineWidth = 6; arrow.lineCapStyle = .round
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 334, y: 200)); head.line(to: NSPoint(x: 352, y: 220)); head.line(to: NSPoint(x: 328, y: 228))
    head.lineWidth = 6; head.lineCapStyle = .round; head.lineJoinStyle = .round
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 0), blur: 10, color: goldBottom.withAlphaComponent(0.6).cgColor)
    goldBottom.setStroke(); arrow.stroke(); head.stroke()
    cg.restoreGState()
    goldTop.withAlphaComponent(0.7).setStroke()
    let shine = arrow.copy() as! NSBezierPath; shine.lineWidth = 2; shine.stroke()

    text("Drag FairCopy to Applications", .systemFont(ofSize: 13, weight: .semibold), ink.withAlphaComponent(0.75), y: 330)
    text("First launch: System Settings → Privacy & Security → Open Anyway",
         .systemFont(ofSize: 11), ink.withAlphaComponent(0.5), y: 352)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
render(scale: 1, to: dir.appendingPathComponent("background.png"))
render(scale: 2, to: dir.appendingPathComponent("background@2x.png"))

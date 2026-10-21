// Artwork.swift —— 用 CoreGraphics / AppKit 直接绘制图标与 DMG 背景
//
//   swiftc -O Artwork.swift -o build/artwork
//   ./build/artwork icon build/AppIcon-1024.png
//   ./build/artwork dmg  build/dmg-bg.png
//
// 为什么不用 AI 生成图：macOS 图标有固定比例（圆角方形内缩 80/1024、圆角 190/1024），
// 矢量绘制能保证 16pt 下依然清晰，也避免生成模型把云/开关画歪。

import AppKit
import CoreGraphics

// MARK: - 调色

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: a)
}

let blueTop    = hex(0x4C9BFF)
let blueBottom = hex(0x0B51D8)
let glyphBlue  = hex(0x1657D6)

// MARK: - 画布

func canvas(_ w: Int, _ h: Int, _ body: (CGSize) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    body(CGSize(width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "art", code: 1)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - 图标

func drawIcon(_ size: CGSize) {
    let W = size.width
    let s = W / 1024.0          // 以 1024 为设计基准，等比缩放

    // 1. 圆角方形（macOS 规范：内缩 80，圆角 190）
    let inset: CGFloat = 80 * s
    let body = NSRect(x: inset, y: inset, width: W - inset * 2, height: W - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 190 * s, yRadius: 190 * s)

    // 投影（让图标从桌面"浮起来"）
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 26 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    hex(0x0B51D8).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 2. 蓝紫渐变底
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: blueTop, ending: blueBottom)?.draw(in: body, angle: -90)

    // 顶部高光，营造玻璃质感
    let gloss = NSBezierPath(rect: NSRect(x: body.minX, y: body.midY,
                                          width: body.width, height: body.height / 2))
    NSGradient(starting: NSColor.white.withAlphaComponent(0.20),
               ending: NSColor.white.withAlphaComponent(0.0))?.draw(in: gloss, angle: -90)

    // 3. 白云（三个圆 + 圆角底座，同一路径合并）
    // 整体下移 80，让构图在方形里垂直居中
    NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: -80 * s)
    let cloud = NSBezierPath()
    func blob(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        cloud.appendOval(in: NSRect(x: (cx - r) * s, y: (cy - r) * s,
                                    width: r * 2 * s, height: r * 2 * s))
    }
    blob(392, 600, 118)
    blob(520, 646, 156)
    blob(648, 596, 120)
    cloud.appendRoundedRect(NSRect(x: 300 * s, y: 470 * s, width: 424 * s, height: 176 * s),
                            xRadius: 88 * s, yRadius: 88 * s)

    let cloudShadow = NSShadow()
    cloudShadow.shadowColor = hex(0x05307F, 0.30)
    cloudShadow.shadowBlurRadius = 22 * s
    cloudShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    NSGraphicsContext.saveGraphicsState()
    cloudShadow.set()
    NSColor.white.setFill()
    cloud.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 4. 电源符号（通用"开/关"语意，16pt 下也能认出）
    // 云朵在 y≈470..802（设计坐标），符号整体落在云朵内部
    let cx: CGFloat = 512 * s, cy: CGFloat = 585 * s, r: CGFloat = 88 * s
    let stroke: CGFloat = 32 * s

    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r,
                  startAngle: 128, endAngle: 412, clockwise: false)
    arc.lineWidth = stroke
    arc.lineCapStyle = .round

    let bar = NSBezierPath()
    bar.move(to: NSPoint(x: cx, y: cy + 22 * s))
    bar.line(to: NSPoint(x: cx, y: cy + r + 30 * s))
    bar.lineWidth = stroke
    bar.lineCapStyle = .round

    glyphBlue.setStroke()
    arc.stroke()
    bar.stroke()

    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - DMG 背景
// 设计基准 1800×880（对应 900×440pt 的 Finder 窗口 @2x）
// 三个图标摆一行：App（左）→ 箭头 → 应用程序（中）→ 使用说明.txt（右）

func drawDMGBG(_ size: CGSize) {
    let W = size.width, H = size.height
    let s = W / 1800.0

    // 底色：很浅的蓝灰，跟 Finder 深色/浅色都不打架
    NSGradient(starting: hex(0xF7F9FD), ending: hex(0xE6ECF7))?
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    let pStyle = NSMutableParagraphStyle()
    pStyle.alignment = .center

    // 顶部标题
    ("云枢开关" as NSString).draw(in: NSRect(x: 0, y: H - 150 * s, width: W, height: 80 * s),
        withAttributes: [
          .font: NSFont(name: "PingFang SC Semibold", size: 52 * s)
                 ?? NSFont.boldSystemFont(ofSize: 52 * s),
          .foregroundColor: hex(0x1B2C4B),
          .paragraphStyle: pStyle
        ])
    ("把左边的 App 拖到「应用程序」文件夹，就装好了" as NSString).draw(
        in: NSRect(x: 0, y: H - 215 * s, width: W, height: 50 * s),
        withAttributes: [
          .font: NSFont(name: "PingFang SC", size: 27 * s)
                 ?? NSFont.systemFont(ofSize: 27 * s),
          .foregroundColor: hex(0x5A6B85),
          .paragraphStyle: pStyle
        ])

    // 中间箭头：App(130..250pt) 与 应用程序(390..510pt) 之间
    let y = 440 * s
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 545 * s, y: y))
    arrow.line(to: NSPoint(x: 745 * s, y: y))
    arrow.lineWidth = 10 * s
    arrow.lineCapStyle = .round
    hex(0x9FB4D4).setStroke()
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 775 * s, y: y))
    head.line(to: NSPoint(x: 722 * s, y: y + 28 * s))
    head.line(to: NSPoint(x: 722 * s, y: y - 28 * s))
    head.close()
    hex(0x9FB4D4).setFill()
    head.fill()

    // 底部提示
    ("首次打开若提示「无法验证开发者」：右键点 App → 打开 → 仍要打开（只需一次）" as NSString).draw(
        in: NSRect(x: 0, y: 66 * s, width: W, height: 42 * s),
        withAttributes: [
          .font: NSFont(name: "PingFang SC", size: 22 * s)
                 ?? NSFont.systemFont(ofSize: 22 * s),
          .foregroundColor: hex(0x8496AE),
          .paragraphStyle: pStyle
        ])
}

// MARK: - 入口

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: artwork icon|dmg <输出.png>")
    exit(64)
}

let out = args[2]
switch args[1] {
case "icon":
    let rep = canvas(1024, 1024) { drawIcon($0) }
    rep.size = NSSize(width: 1024, height: 1024)
    try writePNG(rep, out)
    print("icon -> \(out)")
case "dmg":
    let rep = canvas(1800, 880) { drawDMGBG($0) }
    rep.size = NSSize(width: 1800, height: 880)
    try writePNG(rep, out)
    print("dmg  -> \(out)")
default:
    print("未知模式 \(args[1])")
    exit(64)
}

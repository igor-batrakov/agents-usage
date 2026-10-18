// Рисует иконку приложения 1024×1024 PNG: `swift tools/make-icon.swift <out.png>`.
// Мотив — как в строке меню: три полоски в цветах сервисов с меткой темпа.
// Тело — «сквиркл» по сетке иконок macOS (824 из 1024, поля под тень).
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Суперэллипс |x|^n + |y|^n = 1 — близок к форме иконок Apple (непрерывная кривизна углов).
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func capsule(_ rect: CGRect) -> CGPath {
    let r = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// Тот же цвет светлее на `d` по каждому каналу — верх градиента полоски.
func lighter(_ hex: UInt32, _ d: CGFloat) -> CGColor {
    let p = color(hex).components!
    return CGColor(srgbRed: min(p[0] + d, 1), green: min(p[1] + d, 1), blue: min(p[2] + d, 1), alpha: 1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Координаты сверху вниз — так проще читать раскладку.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)

// Тень под телом.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x17181D))
ctx.fillPath()
ctx.restoreGState()

// Тело: тёмный градиент сверху вниз и мягкий блик у верхнего края.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0x30323C), color(0x131419)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: body.minY), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: body.minY), endRadius: 620, options: [])
ctx.restoreGState()

// Тонкая светлая кромка.
ctx.saveGState()
ctx.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5)))
ctx.setStrokeColor(color(0xFFFFFF, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// Полоски: Claude, Codex, agy — заполнение и метка темпа.
let bars: [(hex: UInt32, used: CGFloat, pace: CGFloat)] = [
    (0xD97757, 0.74, 0.62),
    (0x10A37F, 0.46, 0.55),
    (0x4285F4, 0.88, 0.80),
]
let barW: CGFloat = 584, barH: CGFloat = 88, gap: CGFloat = 62
let left = (size - barW) / 2
var top = (size - (3 * barH + 2 * gap)) / 2
for bar in bars {
    let track = CGRect(x: left, y: top, width: barW, height: barH)
    ctx.addPath(capsule(track))
    ctx.setFillColor(color(0xFFFFFF, 0.10))
    ctx.fillPath()

    let fill = CGRect(x: left, y: top, width: barW * bar.used, height: barH)
    ctx.saveGState()
    ctx.addPath(capsule(fill))
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [lighter(bar.hex, 0.12), color(bar.hex)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: fill.minY), end: CGPoint(x: 0, y: fill.maxY), options: [])
    ctx.restoreGState()

    ctx.addPath(capsule(CGRect(x: left + barW * bar.pace - 6, y: top - 14, width: 12, height: barH + 28)))
    ctx.setFillColor(color(0xFFFFFF, 0.9))
    ctx.fillPath()

    top += barH + gap
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("не записан \(out)") }
print("Готово: \(out)")

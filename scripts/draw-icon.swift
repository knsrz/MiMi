import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let variants = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    rgba(
        CGFloat((value >> 16) & 0xFF) / 255.0,
        CGFloat((value >> 8) & 0xFF) / 255.0,
        CGFloat(value & 0xFF) / 255.0,
        alpha
    )
}

/// Official Apple macOS continuous squircle (G2 smooth corners on 824x824 safe area).
func makeSquircle(in rect: CGRect, cornerRadius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let minX = rect.minX, maxX = rect.maxX
    let minY = rect.minY, maxY = rect.maxY
    let c = min(r * 1.528665, min(rect.width, rect.height) * 0.5)
    let k1 = r * 1.088493
    let k2 = r * 0.868407
    let k3 = r * 0.631494
    let k4 = r * 0.372824
    let k5 = r * 0.169060
    let k6 = r * 0.074911

    path.move(to: CGPoint(x: maxX - c, y: maxY))
    path.addCurve(to: CGPoint(x: maxX - k3, y: maxY - k6),
                  control1: CGPoint(x: maxX - k1, y: maxY),
                  control2: CGPoint(x: maxX - k2, y: maxY))
    path.addCurve(to: CGPoint(x: maxX - k6, y: maxY - k3),
                  control1: CGPoint(x: maxX - k4, y: maxY - k5),
                  control2: CGPoint(x: maxX - k5, y: maxY - k4))
    path.addCurve(to: CGPoint(x: maxX, y: maxY - c),
                  control1: CGPoint(x: maxX, y: maxY - k2),
                  control2: CGPoint(x: maxX, y: maxY - k1))

    path.addLine(to: CGPoint(x: maxX, y: minY + c))
    path.addCurve(to: CGPoint(x: maxX - k6, y: minY + k3),
                  control1: CGPoint(x: maxX, y: minY + k1),
                  control2: CGPoint(x: maxX, y: minY + k2))
    path.addCurve(to: CGPoint(x: maxX - k3, y: minY + k6),
                  control1: CGPoint(x: maxX - k5, y: minY + k4),
                  control2: CGPoint(x: maxX - k4, y: minY + k5))
    path.addCurve(to: CGPoint(x: maxX - c, y: minY),
                  control1: CGPoint(x: maxX - k2, y: minY),
                  control2: CGPoint(x: maxX - k1, y: minY))

    path.addLine(to: CGPoint(x: minX + c, y: minY))
    path.addCurve(to: CGPoint(x: minX + k3, y: minY + k6),
                  control1: CGPoint(x: minX + k1, y: minY),
                  control2: CGPoint(x: minX + k2, y: minY))
    path.addCurve(to: CGPoint(x: minX + k6, y: minY + k3),
                  control1: CGPoint(x: minX + k4, y: minY + k5),
                  control2: CGPoint(x: minX + k5, y: minY + k4))
    path.addCurve(to: CGPoint(x: minX, y: minY + c),
                  control1: CGPoint(x: minX, y: minY + k2),
                  control2: CGPoint(x: minX, y: minY + k1))

    path.addLine(to: CGPoint(x: minX, y: maxY - c))
    path.addCurve(to: CGPoint(x: minX + k6, y: maxY - k3),
                  control1: CGPoint(x: minX, y: maxY - k1),
                  control2: CGPoint(x: minX, y: maxY - k2))
    path.addCurve(to: CGPoint(x: minX + k3, y: maxY - k6),
                  control1: CGPoint(x: minX + k5, y: maxY - k4),
                  control2: CGPoint(x: minX + k4, y: maxY - k5))
    path.addCurve(to: CGPoint(x: minX + c, y: maxY),
                  control1: CGPoint(x: minX + k2, y: maxY),
                  control2: CGPoint(x: minX + k1, y: maxY))

    path.closeSubpath()
    return path
}

/// Pure geometric cat head constructed from a true circular cheek with tangent ears.
func makeGeometricCatHead(center: CGPoint, radius hr: CGFloat) -> CGPath {
    let hx = center.x
    let hy = center.y
    let p = CGMutablePath()

    p.move(to: CGPoint(x: hx, y: hy - hr))
    p.addCurve(to: CGPoint(x: hx + hr, y: hy),
               control1: CGPoint(x: hx + hr * 0.552, y: hy - hr),
               control2: CGPoint(x: hx + hr, y: hy - hr * 0.552))
    p.addCurve(to: CGPoint(x: hx + hr * 0.85, y: hy + hr * 1.24),
               control1: CGPoint(x: hx + hr, y: hy + hr * 0.52),
               control2: CGPoint(x: hx + hr * 0.96, y: hy + hr * 0.96))
    p.addQuadCurve(to: CGPoint(x: hx + hr * 0.68, y: hy + hr * 1.26),
                   control: CGPoint(x: hx + hr * 0.79, y: hy + hr * 1.33))
    p.addCurve(to: CGPoint(x: hx, y: hy + hr * 0.84),
               control1: CGPoint(x: hx + hr * 0.42, y: hy + hr * 1.04),
               control2: CGPoint(x: hx + hr * 0.22, y: hy + hr * 0.84))
    p.addCurve(to: CGPoint(x: hx - hr * 0.68, y: hy + hr * 1.26),
               control1: CGPoint(x: hx - hr * 0.22, y: hy + hr * 0.84),
               control2: CGPoint(x: hx - hr * 0.42, y: hy + hr * 1.04))
    p.addQuadCurve(to: CGPoint(x: hx - hr * 0.85, y: hy + hr * 1.24),
                   control: CGPoint(x: hx - hr * 0.79, y: hy + hr * 1.33))
    p.addCurve(to: CGPoint(x: hx - hr, y: hy),
               control1: CGPoint(x: hx - hr * 0.96, y: hy + hr * 0.96),
               control2: CGPoint(x: hx - hr, y: hy + hr * 0.52))
    p.addCurve(to: CGPoint(x: hx, y: hy - hr),
               control1: CGPoint(x: hx - hr, y: hy - hr * 0.552),
               control2: CGPoint(x: hx - hr * 0.552, y: hy - hr))
    p.closeSubpath()
    return p
}

func renderIcon(pixels: Int) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let scale = CGFloat(pixels) / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = makeSquircle(in: tileRect, cornerRadius: 185.4)

    // 1. Clean native macOS Dock shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: rgba(0, 0, 0, 0.20))
    ctx.setFillColor(hex(0xFFFFFF))
    ctx.addPath(squircle)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: rgba(0, 0, 0, 0.12))
    ctx.setFillColor(hex(0xFFFFFF))
    ctx.addPath(squircle)
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Crisp Pure White Squircle
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let bgGrad = CGGradient(
        colorsSpace: space,
        colors: [hex(0xFFFFFF), hex(0xFBFBFC), hex(0xF0F1F4)] as CFArray,
        locations: [0.0, 0.62, 1.0]
    )!
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // 3. Abstract Optical Bauhaus Black Cat (Pure 2-shape Even-Odd Negative Space)
    let bodyRadius: CGFloat = 212
    let bodyCenter = CGPoint(x: 459, y: 459)
    let bodyCircle = CGPath(
        ellipseIn: CGRect(
            x: bodyCenter.x - bodyRadius,
            y: bodyCenter.y - bodyRadius,
            width: bodyRadius * 2,
            height: bodyRadius * 2
        ),
        transform: nil
    )

    let headRadius: CGFloat = 158
    let headCenter = CGPoint(x: 619, y: 577)
    let head = makeGeometricCatHead(center: headCenter, radius: headRadius)

    let combined = CGMutablePath()
    combined.addPath(bodyCircle)
    combined.addPath(head)

    // Silky obsidian-to-graphite studio gradient
    ctx.saveGState()
    ctx.addPath(combined)
    ctx.clip(using: .evenOdd)

    let inkGrad = CGGradient(
        colorsSpace: space,
        colors: [hex(0x040507), hex(0x13151A), hex(0x454A54), hex(0x636873)] as CFArray,
        locations: [0.0, 0.42, 0.82, 1.0]
    )!
    ctx.drawLinearGradient(
        inkGrad,
        start: CGPoint(x: 433, y: 755),
        end: CGPoint(x: 633, y: 245),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // 4. Crisp subtle inner rim
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setLineWidth(2.6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rimGrad = CGGradient(
        colorsSpace: space,
        colors: [rgba(1, 1, 1, 0.95), rgba(0, 0, 0, 0.03), rgba(0, 0, 0, 0.07)] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        rimGrad,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )
    ctx.restoreGState()

    ctx.restoreGState()
    return ctx.makeImage()
}

for (name, pixels) in variants {
    guard let image = renderIcon(pixels: pixels),
          let destination = CGImageDestinationCreateWithURL(
              folder.appending(path: name + ".png") as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

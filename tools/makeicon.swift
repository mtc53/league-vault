import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    let s = size

    // Rounded-square backdrop with a deep blue -> teal gradient.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.05, green: 0.11, blue: 0.22, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.06, green: 0.28, blue: 0.38, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.restoreGState()

    // Shield.
    let w = s * 0.46, h = s * 0.54
    let cx = s / 2, top = s / 2 + h / 2, bottom = s / 2 - h / 2
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: cx - w / 2, y: top))
    shield.addLine(to: CGPoint(x: cx + w / 2, y: top))
    shield.addLine(to: CGPoint(x: cx + w / 2, y: bottom + h * 0.34))
    shield.addQuadCurve(to: CGPoint(x: cx, y: bottom),
                        control: CGPoint(x: cx + w / 2, y: bottom + h * 0.08))
    shield.addQuadCurve(to: CGPoint(x: cx - w / 2, y: bottom + h * 0.34),
                        control: CGPoint(x: cx - w / 2, y: bottom + h * 0.08))
    shield.closeSubpath()

    ctx.saveGState()
    ctx.addPath(shield)
    let gold = [
        NSColor(calibratedRed: 0.96, green: 0.82, blue: 0.45, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.79, green: 0.59, blue: 0.20, alpha: 1).cgColor
    ] as CFArray
    ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gold, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()

    // Keyhole cut into the shield.
    ctx.saveGState()
    ctx.setBlendMode(.destinationOut)
    let r = s * 0.062
    ctx.addEllipse(in: CGRect(x: cx - r, y: s / 2 + s * 0.025 - r, width: r * 2, height: r * 2))
    ctx.fillPath()
    ctx.fill(CGRect(x: cx - s * 0.028, y: s / 2 - s * 0.115, width: s * 0.056, height: s * 0.145))
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                   (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
                   (512, "512x512"), (1024, "512x512@2x")] {
    let img = drawIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("iconset written to \(out)")

import AppKit
import Foundation

// Renders a macOS app icon from a source image — used to build the app icon from the
// 6923 profile icon. Squares get the Big Sur rounded-square mask and a little breathing
// room, so the result sits correctly beside other Dock icons.

let args = CommandLine.arguments
guard args.count > 2 else {
    print("usage: makeicon-from-image <source.png> <output.iconset>")
    exit(1)
}
let sourcePath = args[1]
let out = args[2]

guard let source = NSImage(contentsOfFile: sourcePath) else {
    print("could not read \(sourcePath)")
    exit(1)
}

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    // Dock icons are not full-bleed; leave a margin so it matches its neighbours.
    let inset = size * 0.055
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237   // Big Sur's continuous-corner ratio
    let mask = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    mask.addClip()
    // Fill first: the artwork is opaque, but a transparent source would otherwise
    // punch a hole in the icon.
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    rect.fill()
    source.draw(in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()

    // A hairline edge keeps it from dissolving into a dark Dock.
    NSGraphicsContext.saveGraphicsState()
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    mask.lineWidth = max(1, size * 0.004)
    mask.stroke()
    NSGraphicsContext.restoreGraphicsState()

    image.unlockFocus()
    return image
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                   (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
                   (512, "512x512"), (1024, "512x512@2x")] {
    let img = render(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("iconset written to \(out)")

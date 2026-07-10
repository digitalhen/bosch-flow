// Renders the app icon: white bicycle glyph on a green→blue rounded gradient.
import AppKit

let S = 1024.0
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// rounded background with a diagonal gradient (matches dashboard accents)
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S),
                      xRadius: S * 0.225, yRadius: S * 0.225)
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.31, green: 0.82, blue: 0.65, alpha: 1),
    NSColor(srgbRed: 0.36, green: 0.61, blue: 1.00, alpha: 1),
])!
grad.draw(in: bg, angle: -55)

// white bicycle symbol, centered
if let sym = NSImage(systemSymbolName: "bicycle", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.46, weight: .semibold)
    let s = sym.withSymbolConfiguration(cfg) ?? sym
    let sw = s.size.width, sh = s.size.height
    let r = NSRect(x: (S - sw) / 2, y: (S - sh) / 2, width: sw, height: sh)
    // composite white over the glyph shape
    let tinted = NSImage(size: r.size)
    tinted.lockFocus()
    s.draw(in: NSRect(origin: .zero, size: r.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: r.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: r)
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

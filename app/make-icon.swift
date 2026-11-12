// Draws the app icon and writes a 1024-pixel PNG to the path given as the first argument.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// The standard macOS icon shape: a rounded square inset from the canvas, with a soft shadow.
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
context.addPath(shape)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shape)
context.clip()
let colors = [NSColor(red: 0.36, green: 0.33, blue: 0.93, alpha: 1).cgColor, NSColor(red: 0.62, green: 0.45, blue: 1.0, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
context.restoreGState()

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, at point: CGPoint) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
    string.draw(at: point)
}
draw("π", size: 560, weight: .semibold, at: CGPoint(x: 250, y: 190))
draw("2", size: 250, weight: .bold, at: CGPoint(x: 620, y: 560))
image.unlockFocus()

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render the icon")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

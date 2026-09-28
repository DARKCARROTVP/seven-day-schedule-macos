import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 208, yRadius: 208)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.47, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.36, green: 0.25, blue: 0.88, alpha: 1)
])!
gradient.draw(in: background, angle: -55)

let page = NSBezierPath(roundedRect: NSRect(x: 208, y: 190, width: 608, height: 638), xRadius: 76, yRadius: 76)
NSColor.white.setFill()
page.fill()

let top = NSBezierPath()
top.move(to: NSPoint(x: 208, y: 690))
top.line(to: NSPoint(x: 816, y: 690))
top.line(to: NSPoint(x: 816, y: 752))
top.curve(to: NSPoint(x: 740, y: 828), controlPoint1: NSPoint(x: 816, y: 794), controlPoint2: NSPoint(x: 782, y: 828))
top.line(to: NSPoint(x: 284, y: 828))
top.curve(to: NSPoint(x: 208, y: 752), controlPoint1: NSPoint(x: 242, y: 828), controlPoint2: NSPoint(x: 208, y: 794))
top.close()
NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.85, alpha: 1).setFill()
top.fill()

for x in [330.0, 694.0] {
    let ring = NSBezierPath(roundedRect: NSRect(x: x - 20, y: 770, width: 40, height: 112), xRadius: 20, yRadius: 20)
    NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
    ring.fill()
}

let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 310, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.18, green: 0.40, blue: 0.94, alpha: 1)
]
let seven = NSAttributedString(string: "7", attributes: attributes)
let sevenSize = seven.size()
seven.draw(at: NSPoint(x: (1024 - sevenSize.width) / 2, y: 275))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法生成图标")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

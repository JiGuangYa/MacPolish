import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate_app_icon.swift <output-png-path>\n", stderr)
    exit(EXIT_FAILURE)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvasSize = CGSize(width: 1024, height: 1024)
let fullRect = NSRect(origin: .zero, size: canvasSize)
let pixelsWide = Int(canvasSize.width)
let pixelsHigh = Int(canvasSize.height)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelsWide,
    pixelsHigh: pixelsHigh,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to create bitmap context\n", stderr)
    exit(EXIT_FAILURE)
}

bitmap.size = canvasSize

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Failed to create graphics context\n", stderr)
    exit(EXIT_FAILURE)
}

NSGraphicsContext.current = context

NSColor.clear.setFill()
fullRect.fill()

let baseRect = fullRect.insetBy(dx: 72, dy: 72)
let basePath = NSBezierPath(roundedRect: baseRect, xRadius: 230, yRadius: 230)
let baseGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1.0),
    NSColor(calibratedRed: 0.83, green: 0.85, blue: 0.88, alpha: 1.0)
])!
baseGradient.draw(in: basePath, angle: -90)

NSGraphicsContext.saveGraphicsState()
let outerShadow = NSShadow()
outerShadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.18)
outerShadow.shadowBlurRadius = 30
outerShadow.shadowOffset = NSSize(width: 0, height: -10)
outerShadow.set()
basePath.fill()
NSGraphicsContext.restoreGraphicsState()

let displayFrame = NSRect(x: 188, y: 332, width: 648, height: 352)
let bezelPath = NSBezierPath(roundedRect: displayFrame, xRadius: 66, yRadius: 66)
NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).setFill()
bezelPath.fill()

let screenRect = displayFrame.insetBy(dx: 22, dy: 22)
let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 68, yRadius: 68)
NSColor.black.setFill()
screenPath.fill()

NSGraphicsContext.saveGraphicsState()
screenPath.addClip()

let reflection = NSBezierPath()
reflection.move(to: CGPoint(x: screenRect.minX - 40, y: screenRect.minY + 170))
reflection.line(to: CGPoint(x: screenRect.minX + 130, y: screenRect.minY - 20))
reflection.line(to: CGPoint(x: screenRect.maxX + 40, y: screenRect.maxY - 110))
reflection.line(to: CGPoint(x: screenRect.maxX - 130, y: screenRect.maxY + 20))
reflection.close()

NSColor.white.withAlphaComponent(0.10).setFill()
reflection.fill()

let highlightRect = NSRect(x: screenRect.minX + 60, y: screenRect.maxY - 150, width: screenRect.width * 0.45, height: 52)
let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: 26, yRadius: 26)
NSColor.white.withAlphaComponent(0.14).setFill()
highlightPath.fill()

NSGraphicsContext.restoreGraphicsState()

let hinge = NSBezierPath(roundedRect: NSRect(x: 314, y: 300, width: 396, height: 24), xRadius: 12, yRadius: 12)
NSColor(calibratedRed: 0.63, green: 0.67, blue: 0.72, alpha: 1.0).setFill()
hinge.fill()

let baseTop = NSBezierPath(roundedRect: NSRect(x: 208, y: 222, width: 608, height: 94), xRadius: 32, yRadius: 32)
let keyboardDeckGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.82, green: 0.85, blue: 0.89, alpha: 1.0),
    NSColor(calibratedRed: 0.68, green: 0.72, blue: 0.77, alpha: 1.0)
])!
keyboardDeckGradient.draw(in: baseTop, angle: -90)

let trackpad = NSBezierPath(roundedRect: NSRect(x: 430, y: 242, width: 164, height: 48), xRadius: 16, yRadius: 16)
NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
trackpad.lineWidth = 4
trackpad.stroke()

let lip = NSBezierPath()
lip.move(to: CGPoint(x: 160, y: 228))
lip.line(to: CGPoint(x: 864, y: 228))
lip.line(to: CGPoint(x: 796, y: 180))
lip.line(to: CGPoint(x: 228, y: 180))
lip.close()
NSColor(calibratedRed: 0.64, green: 0.68, blue: 0.74, alpha: 1.0).setFill()
lip.fill()

func drawSparkle(center: CGPoint, scale: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = 18 * scale
    path.lineCapStyle = .round

    path.move(to: CGPoint(x: center.x, y: center.y + 46 * scale))
    path.line(to: CGPoint(x: center.x, y: center.y - 46 * scale))

    path.move(to: CGPoint(x: center.x - 46 * scale, y: center.y))
    path.line(to: CGPoint(x: center.x + 46 * scale, y: center.y))

    path.move(to: CGPoint(x: center.x - 28 * scale, y: center.y - 28 * scale))
    path.line(to: CGPoint(x: center.x + 28 * scale, y: center.y + 28 * scale))

    path.move(to: CGPoint(x: center.x - 28 * scale, y: center.y + 28 * scale))
    path.line(to: CGPoint(x: center.x + 28 * scale, y: center.y - 28 * scale))

    NSColor.white.withAlphaComponent(0.96).setStroke()
    path.stroke()
}

drawSparkle(center: CGPoint(x: 756, y: 650), scale: 1.0)
drawSparkle(center: CGPoint(x: 286, y: 304), scale: 0.52)
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to render icon PNG\n", stderr)
    exit(EXIT_FAILURE)
}

try pngData.write(to: outputURL)

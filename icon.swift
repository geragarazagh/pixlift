// Placeholder icon for the working builds: the four corners of macOS's selection frame around a red
// recording dot. The real icon comes with the real name, shown to him as variants first.
// Usage: ./build runs this: icon <dir> writes <dir>/light.png and <dir>/dark.png.

import AppKit

func render(_ dark: Bool, to url: URL) {
    let s = 1024
    let c = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let ink = dark ? CGColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1) : CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    c.setStrokeColor(ink); c.setLineWidth(56); c.setLineCap(.round); c.setLineJoin(.round)
    let a: CGFloat = 250, b: CGFloat = 774, arm: CGFloat = 150
    for (x, y, dx, dy) in [(a, a, 1.0, 1.0), (b, a, -1.0, 1.0), (a, b, 1.0, -1.0), (b, b, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        c.move(to: CGPoint(x: x, y: y + dy * arm)); c.addLine(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + dx * arm, y: y))
    }
    c.strokePath()
    c.setFillColor(CGColor(srgbRed: 1, green: 0.22, blue: 0.24, alpha: 1))   // systemRed, light appearance
    c.fillEllipse(in: CGRect(x: 512 - 110, y: 512 - 110, width: 220, height: 220))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
render(false, to: dir.appendingPathComponent("light.png"))
render(true, to: dir.appendingPathComponent("dark.png"))

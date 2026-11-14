// Pixlift's icon: the letter P as the Mac's screen draws it, seen under a microscope.
// An Icon Composer icon (macOS 26+ switches it with the theme): this draws only the picture, light.png and dark.png,
// 1024 px, transparent; the plate is the system's own fill (./build writes icon.json and runs actool).
// Usage: ./build runs this: icon <dir> writes <dir>/light.png and <dir>/dark.png.
//
// The letter: the system font, bold, 12 px, whose capital is exactly 9 pixels tall, rasterised here with the grey
// antialiasing the screen really uses. 9 pixels x 64 = 576, the height of STT's wave and HoldQ's Q (the family's grid:
// the old 824 px plate, 100..924, scaled to the canvas).
// The microscope: a field of 13 x 13 pixels at that pitch covers the plate, and every pixel is lit at the colour it has
// there: the system plate around (light ~#FAFAFA, dark ~#1C1C1E, read from the system's own render), the ink of the P
// (#1C1C1E on light, white on dark, as STT, TTS, HoldQ) mixed in by its coverage. The top-left pixel of the P is lifted
// off, half a pixel up and left, and the socket it leaves is bare black matrix: lift pixels off the screen.
// Geometry of a pixel, measured 2026-11-14 on Notebookcheck's microscope photos of MacBook Pro 14 M3, 16 M4 Pro and
// MacBook Air 15 M4 (the LCD stripe every Mac but the newest OLED MacBook Pro has): vertical R, G, B stripes, each 0.27 of
// the pitch wide with 0.063 of black matrix beside it, lit 0.71 of the pitch tall with 0.29 of black matrix between rows.
// Colours of the lit stripes: the median of the lit subpixels of those three photos (#FF6782, #91F0AD, #7659FD), not
// pure primaries: that is what a lit subpixel looks like under the lens, and it keeps a white field reading as white at
// 32 pt, where pure primaries on black averaged to a dark grey and the dark P sank into it.

import AppKit

let lit: [(CGFloat, CGFloat, CGFloat)] = [(0xFF, 0x67, 0x82), (0x91, 0xF0, 0xAD), (0x76, 0x59, 0xFD)].map { ($0 / 255, $1 / 255, $2 / 255) }
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// The letter, row 0 on top, as coverage 0...1; cells under 4 % (invisible on any plate) are dropped.
func glyphP() -> [[CGFloat]] {
    let w = 16, h = 16
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    c.setShouldSmoothFonts(false); c.setAllowsFontSmoothing(false); c.setShouldAntialias(true)
    let a = NSAttributedString(string: "P", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
    c.textPosition = CGPoint(x: 3, y: 3); CTLineDraw(CTLineCreateWithAttributedString(a), c)
    let d = c.data!.assumingMemoryBound(to: UInt8.self)
    let rows = (0..<h).map { y in (0..<w).map { CGFloat(d[y * w + $0]) / 255 } }
    let ys = (0..<h).filter { y in rows[y].contains { $0 > 0.04 } }, xs = (0..<w).filter { x in ys.contains { rows[$0][x] > 0.04 } }
    return ys.map { y in xs.map { x in rows[y][x] > 0.04 ? rows[y][x] : 0 } }
}

// One pixel with its lower-left corner at (x, y), pitch p, its three stripes lit at level v.
func pixel(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ p: CGFloat, _ v: CGFloat) {
    guard v > 0.004 else { return }
    let w = 0.27 * p, h = 0.71 * p
    for (i, l) in lit.enumerated() {
        c.setFillColor(CGColor(colorSpace: sRGB, components: [l.0 * v, l.1 * v, l.2 * v, 1])!)
        c.fill(CGRect(x: x + CGFloat(i) * p / 3 + (p / 3 - w) / 2, y: y + (p - h) / 2, width: w, height: h))
    }
}

func draw(_ light: Bool) -> CGImage {
    let c = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: 1024 / 824, y: 1024 / 824); c.translateBy(x: -100, y: -100)
    let g = glyphP(), p: CGFloat = 64, n = 13
    let plate: CGFloat = light ? 0.98 : 0.11, ink: CGFloat = light ? 0.11 : 1
    let ox = 512 - CGFloat(n) * p / 2, top = 512 + CGFloat(n) * p / 2
    let gi = (n - g[0].count) / 2, gj = (n - g.count) / 2
    var lift = (0, 0)
    search: for j in g.indices { for i in g[0].indices where g[j][i] > 0.9 { lift = (i + gi, j + gj); break search } }
    func level(_ i: Int, _ j: Int) -> CGFloat {
        let li = i - gi, lj = j - gj
        let cov = g[0].indices.contains(li) && g.indices.contains(lj) ? g[lj][li] : 0
        return plate * (1 - cov) + ink * cov
    }
    c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: ox, y: top - CGFloat(n) * p, width: CGFloat(n) * p, height: CGFloat(n) * p))
    for j in 0..<n { for i in 0..<n where (i, j) != lift { pixel(c, ox + CGFloat(i) * p, top - CGFloat(j + 1) * p, p, level(i, j)) } }
    // The lifted pixel: half a pixel up and left, a little nearer (x 1.12), its shadow falling into its socket.
    let s = p * 1.12, x = ox + CGFloat(lift.0) * p - p * 0.5 - (s - p) / 2, y = top - CGFloat(lift.1 + 1) * p + p * 0.5 - (s - p) / 2
    c.saveGState()
    c.setShadow(offset: CGSize(width: p * 0.5, height: -p * 0.5), blur: p * 0.35, color: CGColor(gray: 0, alpha: 0.9))
    c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: x, y: y, width: s, height: s))
    c.restoreGState()
    pixel(c, x, y, s, level(lift.0, lift.1))
    return c.makeImage()!
}

for (name, light) in [("light", true), ("dark", false)] {
    let rep = NSBitmapImageRep(cgImage: draw(light))
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/\(name).png"))
}

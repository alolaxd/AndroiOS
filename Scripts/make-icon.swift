// Draws AndroiOS's app icon (1024×1024, flat): an iPhone outline holding the
// Android robot head. The Android robot is reproduced/modified from work created
// and shared by Google, used under the Creative Commons 3.0 Attribution License.
//   swift Scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Top-left origin, like the design coordinates below.
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, 1])! }
let background = rgb(22, 24, 27)      // near-black, iOS dark
let white = rgb(245, 245, 247)
let green = rgb(61, 220, 132)         // Android green #3DDC84

ctx.setFillColor(background)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Phone outline
let phone = CGRect(x: 262, y: 112, width: 500, height: 800)
ctx.setStrokeColor(white)
ctx.setLineWidth(40)
ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 104, cornerHeight: 104, transform: nil))
ctx.strokePath()
// Dynamic Island
ctx.setFillColor(white)
ctx.addPath(CGPath(roundedRect: CGRect(x: 452, y: 176, width: 120, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
ctx.fillPath()

// Android head: half disc with a flat bottom
let center = CGPoint(x: 512, y: 640), r: CGFloat = 170
ctx.setFillColor(green)
ctx.move(to: CGPoint(x: center.x - r, y: center.y))
ctx.addArc(center: center, radius: r, startAngle: .pi, endAngle: 0, clockwise: false)
ctx.closePath()
ctx.fillPath()

// Antennae
ctx.setStrokeColor(green)
ctx.setLineWidth(20)
ctx.setLineCap(.round)
for side: CGFloat in [-1, 1] {
    let base = CGPoint(x: center.x + side * 92, y: center.y - 136)
    ctx.move(to: base)
    ctx.addLine(to: CGPoint(x: base.x + side * 44, y: base.y - 72))
}
ctx.strokePath()

// Eyes
ctx.setFillColor(background)
for side: CGFloat in [-1, 1] {
    ctx.fillEllipse(in: CGRect(x: center.x + side * 70 - 20, y: center.y - 78 - 20, width: 40, height: 40))
}

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(url.path)")

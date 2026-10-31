import AppKit
import CoreGraphics

// 黑果短剧 App 图标：1024×1024，不透明。
let size = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
let S = CGFloat(size)

// 背景：深炭灰到黑的径向渐变，左上带一点暖红辉光
let bg = CGGradient(colorsSpace: cs, colors: [c(0.20, 0.07, 0.09), c(0.07, 0.06, 0.08), c(0.02, 0.02, 0.03)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: S * 0.32, y: S * 0.78), startRadius: 0,
                       endCenter: CGPoint(x: S * 0.5, y: S * 0.5), endRadius: S * 0.85, options: [.drawsAfterEndLocation])

// 果实（坐标系原点在左下）
let center = CGPoint(x: S * 0.5, y: S * 0.45)
let radius = S * 0.30

// 投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.025), blur: S * 0.06, color: c(0, 0, 0, 0.75))
ctx.setFillColor(c(0.05, 0.05, 0.06))
ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.restoreGState()

// 果实本体：黑紫色径向渐变，右下暗、左上亮
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.clip()
let body = CGGradient(colorsSpace: cs, colors: [c(0.30, 0.27, 0.33), c(0.10, 0.09, 0.12), c(0.02, 0.02, 0.03)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawRadialGradient(body, startCenter: CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.40), startRadius: 0,
                       endCenter: center, endRadius: radius * 1.05, options: [.drawsAfterEndLocation])
// 边缘一圈暖红反光
ctx.setStrokeColor(c(0.85, 0.18, 0.22, 0.35))
ctx.setLineWidth(S * 0.012)
ctx.addEllipse(in: CGRect(x: center.x - radius + S * 0.004, y: center.y - radius + S * 0.004, width: radius * 2 - S * 0.008, height: radius * 2 - S * 0.008))
ctx.strokePath()
ctx.restoreGState()

// 高光：左上一个柔和的白色椭圆
ctx.saveGState()
let hl = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.55), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
let hlCenter = CGPoint(x: center.x - radius * 0.42, y: center.y + radius * 0.48)
ctx.translateBy(x: hlCenter.x, y: hlCenter.y)
ctx.rotate(by: .pi / 5)
ctx.scaleBy(x: 1.0, y: 0.55)
ctx.drawRadialGradient(hl, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius * 0.38, options: [])
ctx.restoreGState()

// 果柄
ctx.saveGState()
ctx.setStrokeColor(c(0.30, 0.20, 0.12))
ctx.setLineWidth(S * 0.028)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: center.x, y: center.y + radius * 0.88))
ctx.addCurve(to: CGPoint(x: center.x + S * 0.03, y: center.y + radius + S * 0.10),
             control1: CGPoint(x: center.x - S * 0.005, y: center.y + radius + S * 0.03),
             control2: CGPoint(x: center.x + S * 0.01, y: center.y + radius + S * 0.07))
ctx.strokePath()
ctx.restoreGState()

// 叶子：绿色渐变 + 叶脉
let leafBase = CGPoint(x: center.x + S * 0.025, y: center.y + radius + S * 0.075)
let leafTip = CGPoint(x: center.x + S * 0.24, y: center.y + radius + S * 0.17)
let leaf = CGMutablePath()
leaf.move(to: leafBase)
leaf.addCurve(to: leafTip, control1: CGPoint(x: leafBase.x + S * 0.04, y: leafBase.y + S * 0.13), control2: CGPoint(x: leafTip.x - S * 0.09, y: leafTip.y + S * 0.06))
leaf.addCurve(to: leafBase, control1: CGPoint(x: leafTip.x - S * 0.04, y: leafTip.y - S * 0.11), control2: CGPoint(x: leafBase.x + S * 0.10, y: leafBase.y - S * 0.05))
ctx.saveGState()
ctx.addPath(leaf)
ctx.clip()
let green = CGGradient(colorsSpace: cs, colors: [c(0.45, 0.82, 0.40), c(0.13, 0.50, 0.22)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(green, start: CGPoint(x: leafBase.x, y: leafTip.y + S * 0.05), end: CGPoint(x: leafTip.x, y: leafBase.y - S * 0.05), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.setStrokeColor(c(0.08, 0.35, 0.15, 0.8))
ctx.setLineWidth(S * 0.008)
ctx.setLineCap(.round)
ctx.move(to: leafBase)
ctx.addQuadCurve(to: CGPoint(x: leafTip.x - S * 0.02, y: leafTip.y - S * 0.005), control: CGPoint(x: leafBase.x + S * 0.10, y: leafBase.y + S * 0.06))
ctx.strokePath()
ctx.restoreGState()

// 播放三角：圆角、红色渐变，略向右偏使视觉居中
let triH = radius * 0.80
let triW = triH * 0.88
let tc = CGPoint(x: center.x + triW * 0.10, y: center.y - S * 0.005)
let p1 = CGPoint(x: tc.x - triW / 2, y: tc.y + triH / 2)
let p2 = CGPoint(x: tc.x - triW / 2, y: tc.y - triH / 2)
let p3 = CGPoint(x: tc.x + triW / 2, y: tc.y)
let tri = CGMutablePath()
let r = S * 0.035
tri.move(to: CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2))
tri.addArc(tangent1End: p2, tangent2End: p3, radius: r)
tri.addArc(tangent1End: p3, tangent2End: p1, radius: r)
tri.addArc(tangent1End: p1, tangent2End: p2, radius: r)
tri.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: S * 0.04, color: c(0.95, 0.15, 0.20, 0.65))
ctx.addPath(tri)
ctx.setFillColor(c(0.92, 0.16, 0.22))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tri)
ctx.clip()
let red = CGGradient(colorsSpace: cs, colors: [c(1.0, 0.42, 0.40), c(0.86, 0.10, 0.18)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(red, start: CGPoint(x: tc.x, y: tc.y + triH / 2), end: CGPoint(x: tc.x, y: tc.y - triH / 2), options: [])
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

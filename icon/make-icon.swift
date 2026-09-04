import AppKit
import Foundation

// 深脑 App 图标生成器。矢量绘制后导出整套尺寸 -> iconutil 打成 .icns。
// 不依赖任何设计工具，改一个数就能重出全套。

let S: CGFloat = 1024          // 主画布
// 眼睛和放射线的线宽额外系数。1 = 不额外加粗（等比缩放已经由 ctx.scaleBy 处理）。
// 独立于坐标系统一放大，留出一个「万一小尺寸下这两处显得太细」的调节口。
let boost: CGFloat = 1.0

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    let k = size / S           // 所有坐标按 1024 设计，这里等比缩放
    ctx.scaleBy(x: k, y: k)
    ctx.setAllowsAntialiasing(true)

    // --- 底板：浅暖白，衬托珊瑚红标记 ---
    // 用户给的品牌标记是珊瑚红实心图形、白底。照搬这个关系，不自作主张换成深底反白。
    let bezel = CGRect(x: 0, y: 0, width: S, height: S)
    let plate = CGPath(roundedRect: bezel, cornerWidth: 229, cornerHeight: 229, transform: nil)
    ctx.saveGState()
    ctx.addPath(plate); ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(colorSpace: cs, components: [1.0, 0.99, 0.98, 1])!,
        CGColor(colorSpace: cs, components: [0.99, 0.95, 0.93, 1])!,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
    ctx.restoreGState()

    // --- 标记 ---
    let coral = CGColor(colorSpace: cs, components: [0.94, 0.47, 0.41, 1])!   // 珊瑚红
    ctx.setFillColor(coral)
    ctx.setStrokeColor(coral)
    ctx.setLineCap(.round)

    // 头部侧脸剪影，朝右。坐标系原点在左下。
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 292, y: 310))                    // 后颈根
    head.addCurve(to: CGPoint(x: 292, y: 566),                // 后脑往上（更饱满）
                  control1: CGPoint(x: 280, y: 402), control2: CGPoint(x: 274, y: 486))
    head.addCurve(to: CGPoint(x: 508, y: 742),                // 颅顶左半
                  control1: CGPoint(x: 310, y: 668), control2: CGPoint(x: 392, y: 742))
    head.addCurve(to: CGPoint(x: 678, y: 596),                // 颅顶右半到额头
                  control1: CGPoint(x: 616, y: 742), control2: CGPoint(x: 674, y: 672))
    head.addCurve(to: CGPoint(x: 690, y: 512),                // 额头下到眉骨
                  control1: CGPoint(x: 682, y: 566), control2: CGPoint(x: 688, y: 538))
    head.addLine(to: CGPoint(x: 714, y: 458))                 // 鼻梁（小转折，不是尖楔）
    head.addLine(to: CGPoint(x: 676, y: 446))                 // 鼻底收回
    // 鼻下一路平滑收到下巴，中间不要台阶——有台阶就像戴了口罩
    head.addCurve(to: CGPoint(x: 592, y: 330),
                  control1: CGPoint(x: 672, y: 396), control2: CGPoint(x: 648, y: 344))
    head.addLine(to: CGPoint(x: 592, y: 224))                 // 颈前
    head.addLine(to: CGPoint(x: 292, y: 224))                 // 底部平切（半身裁切）
    head.closeSubpath()
    ctx.addPath(head); ctx.fillPath()

    // 闭着的眼睛：两道向下弯的弧，挖白。安静、内省——这是这个标记的灵魂。
    //
    // 不用 `.clear` 混合模式真挖洞：NSImage.lockFocus() 在大尺寸（1024 一档，
    // 也就是 .icns 里 Finder/Dock 真正用到的那一档）用的位图后端不保证带 alpha
    // 通道，`.clear` 在那种后端上不是"擦成透明"，是"擦成黑"——小尺寸预览
    // 因此一直是对的（挡住了这个问题），Finder 里显示的大图标却是黑眼睛外面
    // 一圈铜锈色的坏结果，直到真正打进 .icns 里才会显形。
    // 背景是近白的暖色渐变，用渐变上的一个近似色直接描边，肉眼分不出跟
    // "真挖洞露出渐变"的差别，而且不依赖任何 alpha 合成行为，两个尺寸都对。
    let plateNearWhite = CGColor(colorSpace: cs, components: [0.995, 0.975, 0.965, 1])!
    ctx.setStrokeColor(plateNearWhite)
    ctx.setLineWidth(22 * boost)
    for cxEye in [CGFloat(454), CGFloat(580)] {
        let eye = CGMutablePath()
        // 闭眼是 ⌒：中间隆起、两端下垂。画成 ‿ 就变成在笑了，整个气质全变。
        // 宽而平缓。弧度一大就变成尖角，看着像皱眉；原标记是安静的。
        // 两只眼要分得开：挨太近会连成一道「胡子」。
        // 弧度也不能太平，平了就成了眉毛。
        eye.move(to: CGPoint(x: cxEye - 33, y: 532))
        eye.addQuadCurve(to: CGPoint(x: cxEye + 33, y: 532), control: CGPoint(x: cxEye, y: 578))
        ctx.addPath(eye); ctx.strokePath()
    }
    ctx.setStrokeColor(coral)

    // 头顶放射线：中间长、两侧短并外倾，像想明白的一瞬间
    ctx.setFillColor(coral)
    ctx.setLineWidth(26 * boost)
    let rayCenter = CGPoint(x: 495, y: 700)
    for (deg, inner, outer) in [(-58.0, 210.0, 268.0), (-38.0, 214.0, 292.0), (-18.0, 214.0, 300.0),
                                (0.0, 214.0, 306.0),
                                (18.0, 214.0, 300.0), (38.0, 214.0, 292.0), (58.0, 210.0, 268.0)] {
        let a = (90 + deg) * .pi / 180
        let p1 = CGPoint(x: rayCenter.x + cos(a) * inner, y: rayCenter.y + sin(a) * inner)
        let p2 = CGPoint(x: rayCenter.x + cos(a) * outer, y: rayCenter.y + sin(a) * outer)
        ctx.move(to: p1); ctx.addLine(to: p2)
    }
    ctx.strokePath()

    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ path: String) {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// iconset 需要的全套尺寸。每档都重新矢量绘制，不是缩放大图——
// 小尺寸下线宽会被等比缩到发虚，重绘能保证 16pt 也清楚。
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
let iconset = "\(out)/深脑.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (px, name) in sizes {
    png(drawIcon(size: CGFloat(px)), "\(iconset)/\(name).png")
}
png(drawIcon(size: 1024), "\(out)/preview-1024.png")
for px in [32, 64, 128] { png(drawIcon(size: CGFloat(px)), "\(out)/check-\(px).png") }
print("已生成 iconset（\(sizes.count) 档）与预览")

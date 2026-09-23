// make-icon.swift —— 生成 PerAppVol 图标
//
//   swiftc -O scripts/make-icon.swift -o build/make-icon -framework AppKit
//   build/make-icon            # 产出 build/AppIcon.iconset + build/AppIcon.icns
//
// 设计：macOS squircle 上三条【位置不同】的滑块 —— 直接表达"每个 App 各自的音量"。
// 用粗笔画保证 16×16 下仍然可辨。

import AppKit

let SIZE: CGFloat = 1024

// ───────────────────────────────────────── 绘制

func drawIcon(_ side: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: side, height: side))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!
    ctx.imageInterpolation = .high

    let scale = side / SIZE
    ctx.cgContext.scaleBy(x: scale, y: scale)

    // —— squircle 背景（macOS 图标圆角约为边长的 22.37%）
    let iconRect = NSRect(x: 0, y: 0, width: SIZE, height: SIZE)
    let squircle = NSBezierPath(roundedRect: iconRect,
                                xRadius: SIZE * 0.2237,
                                yRadius: SIZE * 0.2237)
    squircle.addClip()

    let bg = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.51, blue: 0.98, alpha: 1.0),  // #5B82FA
        NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1.0),  // #8C5CF5
    ])!
    bg.draw(in: iconRect, angle: -60)

    // 微弱高光，避免平板
    let gloss = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.18),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    gloss.draw(in: iconRect, angle: -90)

    // —— 三条滑块（位置不同 = 每 App 各自的音量）
    // 布局：整块 x 190..834，轨道高 58，行距 190，垂直居中
    let trackX: CGFloat = 190
    let trackW: CGFloat = 644
    let trackH: CGFloat = 58
    let rows: [(y: CGFloat, v: CGFloat)] = [
        (688, 0.72),   // 上
        (512, 0.34),   // 中
        (336, 0.90),   // 下
    ]

    for (cy, v) in rows {
        let track = NSRect(x: trackX, y: cy - trackH / 2, width: trackW, height: trackH)

        // 轨道（未填充部分）
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2).fill()

        // 已填充部分
        let filled = NSRect(x: track.minX, y: track.minY,
                            width: trackW * v, height: trackH)
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: filled, xRadius: trackH / 2, yRadius: trackH / 2).fill()

        // 滑块圆点（比轨道高一点，立体感）
        let knobR: CGFloat = 78
        let knob = NSRect(x: trackX + trackW * v - knobR,
                          y: cy - knobR, width: knobR * 2, height: knobR * 2)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    img.unlockFocus()
    return img
}

// ───────────────────────────────────────── 输出

let outDir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// iconutil 需要的文件名
let specs: [(String, CGFloat)] = [
    ("icon_16x16",        16),  ("icon_16x16@2x",   32),
    ("icon_32x32",        32),  ("icon_32x32@2x",   64),
    ("icon_128x128",     128),  ("icon_128x128@2x", 256),
    ("icon_256x256",     256),  ("icon_256x256@2x", 512),
    ("icon_512x512",     512),  ("icon_512x512@2x", 1024),
]

for (name, px) in specs {
    let img = drawIcon(px)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    rep.size = NSSize(width: px, height: px)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("  \(name).png  \(Int(px))x\(Int(px))")
}

// 额外存一张 1024 预览图
let preview = drawIcon(1024)
try! NSBitmapImageRep(data: preview.tiffRepresentation!)!
    .representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "build/AppIcon-preview.png"))
print("  AppIcon-preview.png  (1024)")

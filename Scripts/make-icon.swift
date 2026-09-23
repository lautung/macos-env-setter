// 画出 EnvSetter 的应用图标，打成 .icns。
//
//   swift Scripts/make-icon.swift <输出路径.icns>
//
// 图标是**画出来的**，不是设计工具导出的二进制——仓库里不存任何图片资产，改图标就是改这个文件。
// 为什么这么定见 docs/adr/0002。构建时由 build-app.sh 调用，失败即构建失败（宁可没包，不要没图标的包）。
//
// 画布按 Big Sur 网格：1024 的画布里 824 的主体、圆角 185.4。macOS 26 起系统会把老格式图标归一
// 到这个网格，13–15 不归一但认的就是这个网格，所以同一份图在两边都对。

import AppKit
import CoreGraphics
import Foundation

// 图形语言：两层——后面一张冷色卡、前面一张暖色卡，代表两个互不相通的作用层；前面那张上的
// 提示符说明管的是环境变量。所有尺寸按 1024 画布记，出图时整体缩放。

private let canvas: CGFloat = 1024
private let bodyInset: CGFloat = 100          // 主体左/下边距（824 网格）
private let bodyRadius: CGFloat = 185.4
private let cardSide: CGFloat = 322
private let cardRadius: CGFloat = 76
private let cardOffset: CGFloat = 76          // 两张卡各自偏离中心的对角距离
private let chevronWidth: CGFloat = 88
private let chevronHeight: CGFloat = 108
private let chevronLineWidth: CGFloat = 44
private let chevronMinPixels = 64             // 更小的尺寸只剩噪点，那里只留两张卡（16/32 档的观感更好）

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// 底色深石墨，两层各给一色：冷色（shell 层）在后，暖色（GUI 层）在前。
private let background = (rgb(58, 64, 78), rgb(26, 30, 38))
private let coolCard = (rgb(94, 158, 246), rgb(58, 122, 220))
private let warmCard = (rgb(246, 147, 58), rgb(228, 116, 28))
private let chevronColor = rgb(255, 255, 255, 0.95)

private func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// 在裁剪区内画一道斜向渐变——两张卡都用它，光从左上到右下。
private func fillGradient(_ context: CGContext, clip: CGPath, from: CGColor, to: CGColor, rect: CGRect) {
    context.saveGState()
    context.addPath(clip)
    context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [from, to] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
    context.restoreGState()
}

/// 按目标像素尺寸出图。几何全是比例式的，所以每个尺寸单独画一遍，而不是从 1024 缩下来。
private func iconImage(pixels: Int) -> CGImage {
    let k = CGFloat(pixels) / canvas
    let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    let body = CGRect(
        x: bodyInset * k,
        y: bodyInset * k,
        width: (canvas - 2 * bodyInset) * k,
        height: (canvas - 2 * bodyInset) * k
    )
    fillGradient(context, clip: roundedRect(body, bodyRadius * k),
                 from: background.0, to: background.1, rect: body)

    let side = cardSide * k
    let offset = cardOffset * k
    let center = CGPoint(x: canvas / 2 * k, y: canvas / 2 * k)
    let back = CGRect(x: center.x - side / 2 - offset, y: center.y - side / 2 + offset,
                      width: side, height: side)
    let front = CGRect(x: center.x - side / 2 + offset, y: center.y - side / 2 - offset,
                       width: side, height: side)

    fillGradient(context, clip: roundedRect(back, cardRadius * k),
                 from: coolCard.0, to: coolCard.1, rect: back)
    fillGradient(context, clip: roundedRect(front, cardRadius * k),
                 from: warmCard.0, to: warmCard.1, rect: front)

    if pixels >= chevronMinPixels {
        let w = chevronWidth * k / 2, h = chevronHeight * k / 2
        context.saveGState()
        context.setStrokeColor(chevronColor)
        context.setLineWidth(chevronLineWidth * k)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: front.midX - w, y: front.midY + h))
        context.addLine(to: CGPoint(x: front.midX + w, y: front.midY))
        context.addLine(to: CGPoint(x: front.midX - w, y: front.midY - h))
        context.strokePath()
        context.restoreGState()
    }

    return context.makeImage()!
}

// iconutil 要的是一套固定命名的 PNG。
private let iconsetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

// MARK: - 入口

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("用法：swift Scripts/make-icon.swift <输出路径.icns>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("EnvSetter-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for entry in iconsetEntries {
    let rep = NSBitmapImageRep(cgImage: iconImage(pixels: entry.pixels))
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("画不出 \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(entry.name))
}

try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败（退出码 \(iconutil.terminationStatus)）\n".data(using: .utf8)!)
    exit(1)
}

print("已生成图标：\(output.path)")

#!/usr/bin/env swift
import AppKit

// 產生 app 圖示（tools/AppIcon.icns）。
//
// 自己用 Core Graphics 畫，不用 SF Symbols——Apple 授權禁止把那些符號用在
// app icon 上。圖形：綠色漸層底 + 一支手機 + 左側一個資料夾，中間雙向箭頭，
// 正好是這個 app 的事：在 Mac 與 Android 之間搬檔案。
//
// 重跑：swift tools/make-icon.swift && ./tools/make-app.sh

/// macOS 圖示實際圖形約佔畫布 80%，四周留白（Apple HIG 的比例）
let inset = 0.098

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    ctx.setShouldAntialias(true)

    let pad = size * inset
    let box = CGRect(x: pad, y: pad, width: size - pad * 2, height: size - pad * 2)
    let w = box.width

    // ── 底：圓角方形 + 斜向漸層（Android 綠 → 深青）─────────────
    let radius = w * 0.224
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.24, green: 0.73, blue: 0.40, alpha: 1).cgColor,
        NSColor(srgbRed: 0.05, green: 0.36, blue: 0.42, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: box.minX, y: box.maxY),
                               end: CGPoint(x: box.maxX, y: box.minY), options: [])
    }
    ctx.restoreGState()

    let white = NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1).cgColor
    let ink = NSColor(srgbRed: 0.05, green: 0.36, blue: 0.42, alpha: 1).cgColor

    // ── 右：手機 ────────────────────────────────────────────
    let phone = CGRect(x: box.minX + w * 0.58, y: box.minY + w * 0.20, width: w * 0.26, height: w * 0.48)
    ctx.setFillColor(white)
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: w * 0.045, cornerHeight: w * 0.045, transform: nil))
    ctx.fillPath()
    // 螢幕
    let screen = phone.insetBy(dx: w * 0.025, dy: w * 0.05)
    ctx.setFillColor(ink)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: w * 0.015, cornerHeight: w * 0.015, transform: nil))
    ctx.fillPath()

    // ── 左：資料夾 ──────────────────────────────────────────
    let folder = CGRect(x: box.minX + w * 0.12, y: box.minY + w * 0.30, width: w * 0.34, height: w * 0.26)
    ctx.setFillColor(white)
    let tab = CGRect(x: folder.minX, y: folder.maxY - w * 0.02, width: folder.width * 0.42, height: w * 0.06)
    ctx.addPath(CGPath(roundedRect: tab, cornerWidth: w * 0.02, cornerHeight: w * 0.02, transform: nil))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: folder, cornerWidth: w * 0.03, cornerHeight: w * 0.03, transform: nil))
    ctx.fillPath()

    // ── 中：雙向箭頭（小尺寸省略，避免糊成一團）──────────────
    if size >= 64 {
        ctx.setStrokeColor(white)
        ctx.setLineWidth(max(1, w * 0.03))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let left = folder.maxX + w * 0.035
        let right = phone.minX - w * 0.035
        for (y, toRight) in [(box.minY + w * 0.50, true), (box.minY + w * 0.36, false)] {
            ctx.move(to: CGPoint(x: left, y: y))
            ctx.addLine(to: CGPoint(x: right, y: y))
            let tip = toRight ? right : left
            let back = toRight ? -w * 0.04 : w * 0.04
            ctx.move(to: CGPoint(x: tip + back, y: y + w * 0.035))
            ctx.addLine(to: CGPoint(x: tip, y: y))
            ctx.addLine(to: CGPoint(x: tip + back, y: y - w * 0.035))
            ctx.strokePath()
        }
    }

    image.unlockFocus()
    return image
}

// ── 輸出 iconset 並打包成 .icns ───────────────────────────────
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// iconutil 只認這組固定檔名；512@2x（1024）一定要有，Finder 大圖預覽才不會糊
let entries: [(size: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (size, name) in entries {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("產不出 \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil 失敗\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)   // iconset 只是中繼產物
print("已產出 \(root.appendingPathComponent("AppIcon.icns").path)")

#!/usr/bin/env swift
import Cocoa

// ── 設定 ──────────────────────────────────────────────
let outputPath = "/tmp/AppIcon.iconset"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

// ── 描画関数 ──────────────────────────────────────────
func drawIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // 背景：角丸正方形（macOSアイコン形状）
    let radius = s * 0.22
    let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                               xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.12, alpha: 1).setFill() // #0a0f1e
    bgPath.fill()

    // 内枠（薄いボーダー）
    let borderPath = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: s-2, height: s-2),
                                   xRadius: radius-1, yRadius: radius-1)
    NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.25, alpha: 1).setStroke() // #1a2540
    borderPath.lineWidth = s * 0.02
    borderPath.stroke()

    // ── プログレスバー2本 ──
    let barH      = s * 0.10
    let barW      = s * 0.62
    let barRadius = barH / 2
    let centerX   = s * 0.50
    let gap       = s * 0.08

    let totalH  = barH * 2 + gap
    let startY  = (s - totalH) / 2

    let trackColor   = NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.16, alpha: 1)
    let sessionColor = NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1) // #3b82f6
    let weeklyColor  = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 1) // #f59e0b

    let sessionFill: CGFloat = 0.37
    let weeklyFill:  CGFloat = 0.08

    func drawBar(y: CGFloat, fillColor: NSColor, fillRatio: CGFloat) {
        let barX = centerX - barW / 2
        let track = NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: barW, height: barH),
                                  xRadius: barRadius, yRadius: barRadius)
        trackColor.setFill()
        track.fill()
        let fw = barW * fillRatio
        if fw > barRadius * 2 {
            let fill = NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: fw, height: barH),
                                     xRadius: barRadius, yRadius: barRadius)
            fillColor.setFill()
            fill.fill()
        }
    }

    let upperY = startY + barH + gap
    let lowerY = startY

    drawBar(y: upperY, fillColor: sessionColor, fillRatio: sessionFill)
    drawBar(y: lowerY, fillColor: weeklyColor,  fillRatio: weeklyFill)

    // ラベル "C"（64px以上のサイズのみ）
    if size >= 64 {
        let fontSize = s * 0.14
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.29, green: 0.44, blue: 0.63, alpha: 0.6)
        ]
        let str = NSAttributedString(string: "C", attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(x: centerX - strSize.width / 2,
                             y: upperY + barH + s * 0.06))
    }

    image.unlockFocus()
    return image
}

// ── 出力 ─────────────────────────────────────────────
let fm = FileManager.default
try? fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

for size in sizes {
    for scale in [1, 2] {
        let px = size * scale
        let img = drawIcon(size: px)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("❌ Failed at \(px)px")
            continue
        }
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let path = "\(outputPath)/\(name)"
        try! png.write(to: URL(fileURLWithPath: path))
        print("✅ \(name)")
    }
}

// iconset → icns
let icnsPath = "/tmp/AppIcon.icns"
let result = shell("iconutil -c icns \(outputPath) -o \(icnsPath)")
print(result.isEmpty ? "✅ AppIcon.icns → \(icnsPath)" : "iconutil: \(result)")

func shell(_ cmd: String) -> String {
    let t = Process(); let p = Pipe()
    t.launchPath = "/bin/zsh"; t.arguments = ["-c", cmd]
    t.standardOutput = p; t.standardError = p
    t.launch(); t.waitUntilExit()
    return String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

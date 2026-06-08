import AppKit

// メニューバーに表示するミニプログレスバー×2のカスタムビュー
final class StatusBarView: NSView {

    // MARK: - Layout constants
    private let barWidth: CGFloat   = 52
    private let barHeight: CGFloat  = 4
    private let barRadius: CGFloat  = 2
    private let barGap: CGFloat     = 4
    private let labelWidth: CGFloat = 28
    private let fontSize: CGFloat   = 10
    private let hPad: CGFloat       = 6

    // MARK: - State
    var sessionPct: Int = 0  { didSet { needsDisplay = true } }
    var weeklyPct:  Int = 0  { didSet { needsDisplay = true } }
    var isStale:    Bool = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: hPad + barWidth + 2 + labelWidth + hPad, height: 22)
    }

    // MARK: - Colors

    private func barColor(for pct: Int) -> NSColor {
        if isStale         { return NSColor(hex: "#374151") }
        if pct > 95        { return NSColor(hex: "#ef4444") }
        if pct >= 80       { return NSColor(hex: "#f59e0b") }
        return                      NSColor(hex: "#3b82f6")
    }

    private func textColor(for pct: Int) -> NSColor {
        if isStale         { return NSColor(hex: "#374151") }
        if pct > 95        { return NSColor(hex: "#f87171") }
        if pct >= 80       { return NSColor(hex: "#fbbf24") }
        return                      NSColor(hex: "#60a5fa")
    }

    private let trackColor = NSColor(hex: "#111827")

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        let totalBarHeight = barHeight * 2 + barGap
        let topY = (bounds.height - totalBarHeight) / 2

        drawBar(pct: sessionPct, y: topY + barHeight + barGap)
        drawBar(pct: weeklyPct,  y: topY)

        drawLabel(pct: sessionPct, y: topY + barHeight + barGap)
        drawLabel(pct: weeklyPct,  y: topY)

        if isStale {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize - 1),
                .foregroundColor: NSColor(hex: "#374151")
            ]
            let str = NSAttributedString(string: "⚠", attributes: attrs)
            str.draw(at: NSPoint(x: hPad - 1, y: topY + barHeight + barGap - 1))
        }
    }

    private func drawBar(pct: Int, y: CGFloat) {
        let x = hPad
        // トラック（背景）
        let trackPath = NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: barWidth, height: barHeight),
            xRadius: barRadius, yRadius: barRadius
        )
        trackColor.setFill()
        trackPath.fill()

        // 塗り（使用済み）
        let fillWidth = barWidth * CGFloat(max(0, min(100, pct))) / 100
        if fillWidth > 0 {
            let fillPath = NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: fillWidth, height: barHeight),
                xRadius: barRadius, yRadius: barRadius
            )
            barColor(for: pct).setFill()
            fillPath.fill()
        }
    }

    private func drawLabel(pct: Int, y: CGFloat) {
        let x = hPad + barWidth + 2
        let label = isStale ? "--%" : "\(pct)%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: textColor(for: pct)
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let strSize = str.size()
        // 右寄せ
        let drawX = x + labelWidth - strSize.width
        str.draw(at: NSPoint(x: drawX, y: y - 0.5))
    }
}

// MARK: - NSColor hex helper

private extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >>  8) & 0xFF) / 255,
            blue:  CGFloat( rgb        & 0xFF) / 255,
            alpha: 1
        )
    }
}

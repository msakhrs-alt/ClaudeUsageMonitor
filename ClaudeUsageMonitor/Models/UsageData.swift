import AppKit

struct UsageData {
    var sessionUsagePct: Int
    var sessionResetSeconds: Int
    var weeklyUsagePct: Int
    var weeklyResetAt: Date?
    var fetchedAt: Date

    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 600
    }

    var statusBarTitle: String {
        "\(sessionUsagePct)% | \(weeklyUsagePct)%"
    }

    var statusBarColor: NSColor {
        let max = Swift.max(sessionUsagePct, weeklyUsagePct)
        if isStale { return .gray }
        if max > 80 { return .systemRed }
        if max > 50 { return .systemOrange }
        return .systemGreen
    }

    var sessionResetCountdown: String {
        let h = sessionResetSeconds / 3600
        let m = (sessionResetSeconds % 3600) / 60
        let s = sessionResetSeconds % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, s)
    }
}

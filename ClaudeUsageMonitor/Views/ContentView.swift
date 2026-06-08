import SwiftUI

class ContentViewModel: ObservableObject {
    @Published var usageData: UsageData?
    @Published var isLoading = false
    @Published var updateAvailable: String?
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
}

// MARK: - Design tokens

private extension Color {
    static let dsBackground  = Color(hex: "#0a0f1e")
    static let dsBorder      = Color(hex: "#1a2540")
    static let dsTrack       = Color(hex: "#111827")
    static let dsLabel       = Color(hex: "#4a6fa5")
    static let dsSubtext     = Color(hex: "#4a6fa5")
    static let dsNormal      = Color(hex: "#60a5fa")
    static let dsWarning     = Color(hex: "#fbbf24")
    static let dsDanger      = Color(hex: "#f87171")
    static let dsBarNormal   = Color(hex: "#3b82f6")
    static let dsBarWarning  = Color(hex: "#f59e0b")
    static let dsBarDanger   = Color(hex: "#ef4444")
    static let dsButton      = Color(hex: "#111827")
    static let dsButtonHover = Color(hex: "#1a2540")

    init(hex: String) {
        var s = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }

    static func usageText(_ pct: Int) -> Color {
        if pct > 95  { return .dsDanger }
        if pct >= 80 { return .dsWarning }
        return .dsNormal
    }
}

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject var viewModel: ContentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // 更新バナー
            if let version = viewModel.updateAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.dsNormal)
                    Text("Update available: \(version)")
                        .font(.system(size: 11))
                        .foregroundColor(.dsNormal)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.dsBorder)
                .cornerRadius(6)
            }

            if let data = viewModel.usageData {
                // SESSION
                UsageSectionView(
                    label: "SESSION",
                    pct: data.sessionUsagePct,
                    subtext: data.isStale ? "⚠ Data stale (>10min)" : "Resets in \(data.sessionResetCountdown)"
                )

                Divider().background(Color.dsBorder)

                // WEEKLY
                UsageSectionView(
                    label: "WEEKLY",
                    pct: data.weeklyUsagePct,
                    subtext: {
                        if let d = data.weeklyResetAt {
                            let fmt = DateFormatter()
                            fmt.dateFormat = "M/d HH:mm"
                            return "Resets \(fmt.string(from: d))"
                        }
                        return ""
                    }()
                )

            } else if viewModel.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.dsLabel)
                    Text("Loading...")
                        .font(.system(size: 11))
                        .foregroundColor(.dsLabel)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)

            } else {
                Text("No data. Click ↻ to refresh.")
                    .font(.system(size: 11))
                    .foregroundColor(.dsLabel)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }

            Divider().background(Color.dsBorder)

            // ボタン行
            HStack(spacing: 8) {
                DSButton(label: "↻  Refresh") {
                    viewModel.isLoading = true
                    viewModel.onRefresh?()
                }
                Spacer()
                DSButton(label: "Quit") {
                    viewModel.onQuit?()
                }
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(Color.dsBackground)
    }
}

// MARK: - UsageSectionView

private struct UsageSectionView: View {
    let label: String
    let pct: Int
    let subtext: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundColor(.dsLabel)
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundColor(Color.usageText(pct))
            }

            DSProgressBar(pct: pct)

            if !subtext.isEmpty {
                Text(subtext)
                    .font(.system(size: 10))
                    .foregroundColor(.dsSubtext)
            }
        }
    }
}

// MARK: - DSProgressBar

private struct DSProgressBar: View {
    let pct: Int

    private var barColor: Color {
        if pct > 95  { return .dsBarDanger }
        if pct >= 80 { return .dsBarWarning }
        return .dsBarNormal
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.dsTrack)
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(width: geo.size.width * CGFloat(max(0, min(100, pct))) / 100,
                           height: 6)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - DSButton

private struct DSButton: View {
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.dsLabel)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isHovered ? Color.dsButtonHover : Color.dsButton)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

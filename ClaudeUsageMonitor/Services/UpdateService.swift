import Foundation

class UpdateService {
    static let shared = UpdateService()
    // GitHubリポジトリを公開した場合はオーナー名を設定する
    private let repoOwner = "msakhrs-alt"
    private let repoName = "ClaudeUsageMonitor"
    var latestVersion: String?

    private init() {}

    func checkForUpdates() async {
        guard !repoOwner.isEmpty else { return }
        let urlStr = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlStr) else { return }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }

        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        if tag != current {
            await MainActor.run { self.latestVersion = tag }
        }
    }
}

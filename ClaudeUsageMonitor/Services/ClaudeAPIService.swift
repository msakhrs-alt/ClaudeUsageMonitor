import WebKit

@MainActor
protocol ClaudeAPIServiceDelegate: AnyObject {
    func didReceiveUsageData(_ data: UsageData)
    func didFailToFetchUsageData(_ error: Error)
    func needsLogin()
}

@MainActor
class ClaudeAPIService: NSObject {
    weak var delegate: ClaudeAPIServiceDelegate?
    private var webView: WKWebView!
    private var offscreenWindow: NSWindow?

    private let usageURL = URL(string: "https://claude.ai/settings/usage")!

    private let fetchJS = """
    // 1. /api/organizations で org UUID を直接取得
    const orgsRes = await fetch('/api/organizations', { credentials: 'include' });
    if (!orgsRes.ok) {
        return JSON.stringify({ error: 'organizations fetch failed', status: orgsRes.status });
    }
    const orgs = await orgsRes.json();

    // 2. UUID を収集（配列 or オブジェクト両対応）
    const orgUuids = new Set();
    const orgList = Array.isArray(orgs) ? orgs : (orgs.organizations || orgs.data || []);
    orgList.forEach(o => {
        if (o.uuid) orgUuids.add(o.uuid);
        if (o.id)   orgUuids.add(o.id);
    });

    if (orgUuids.size === 0) {
        return JSON.stringify({ error: 'no org uuid found', raw: JSON.stringify(orgs).slice(0, 500) });
    }

    // 3. 各 org UUID で /usage を叩き、200 が返ったものを使う
    for (const uuid of orgUuids) {
        const r = await fetch('/api/organizations/' + uuid + '/usage', { credentials: 'include' });
        if (r.ok) {
            const data = await r.json();
            return JSON.stringify({ org_uuid: uuid, usage: data });
        }
    }
    return JSON.stringify({ error: 'no usage data found', orgs: [...orgUuids] });
    """

    override init() {
        super.init()
        setupWebView()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        // メモリ節約のため小さいサイズ
        let windowRect = NSRect(x: -4000, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        window.contentView!.addSubview(webView)
        window.orderBack(nil)
        offscreenWindow = window

        // ページキャッシュ無効化でメモリ節約
        let prefs = WKWebpagePreferences()
        webView.configuration.defaultWebpagePreferences = prefs

        NSLog("[ClaudeMonitor] WebView setup complete")
    }

    func fetchUsage() {
        NSLog("[ClaudeMonitor] fetchUsage: loading %@", usageURL.absoluteString)
        webView.load(URLRequest(url: usageURL))
    }

    // MARK: - JS evaluation after page load

    private func evaluateUsageJS() {
        NSLog("[ClaudeMonitor] evaluating fetchJS...")
        // callAsyncJavaScript は async/await JS を正しく待機できる (macOS 11+)
        webView.callAsyncJavaScript(fetchJS, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                NSLog("[ClaudeMonitor] JS error: %@", error.localizedDescription)
            case .success(let value):
                guard let jsonStr = value as? String else {
                    NSLog("[ClaudeMonitor] JS result not String: %@", String(describing: value))
                    return
                }
                NSLog("[ClaudeMonitor] JS result: %@", String(jsonStr.prefix(1000)))
                self.parseResults(jsonStr)
                // メモリ解放: JS取得完了後にブランクページへ戻す
                self.webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
            }
        }
    }

    // MARK: - Parse

    private func parseResults(_ jsonStr: String) {
        NSLog("[ClaudeMonitor] parseResults")

        guard let data = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[ClaudeMonitor] parseResults: not a dict")
            return
        }

        if let err = root["error"] as? String {
            NSLog("[ClaudeMonitor] ❌ %@ orgs=%@", err, String(describing: root["orgs"]))
            return
        }

        guard let usageDict = root["usage"] as? [String: Any] else {
            NSLog("[ClaudeMonitor] no 'usage' key in result")
            return
        }

        let orgUUID = root["org_uuid"] as? String ?? "?"
        NSLog("[ClaudeMonitor] usage received for org %@", orgUUID)

        if let parsed = parseUsageDict(usageDict) {
            NSLog("[ClaudeMonitor] ✅ session=%d%% reset=%ds weekly=%d%%",
                  parsed.sessionUsagePct, parsed.sessionResetSeconds, parsed.weeklyUsagePct)
            delegate?.didReceiveUsageData(parsed)
        } else {
            NSLog("[ClaudeMonitor] ❌ parse failed. usage=%@", String(describing: usageDict))
        }
    }

    // {"five_hour":{"utilization":37.0,"resets_at":"2026-06-07T16:30:00.5Z"}, "weekly":{...}? }
    private func parseUsageDict(_ usage: [String: Any]) -> UsageData? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var sessionPct = 0
        var sessionResetSeconds = 0
        var weeklyPct = 0
        var weeklyResetAt: Date?

        // セッション: five_hour キー
        if let fh = usage["five_hour"] as? [String: Any] {
            sessionPct = Int((fh["utilization"] as? Double ?? 0).rounded())
            if let resetsAtStr = fh["resets_at"] as? String,
               let resetsAt = formatter.date(from: resetsAtStr) {
                sessionResetSeconds = max(0, Int(resetsAt.timeIntervalSinceNow))
            }
        }

        // 週間: seven_day キー
        if let wk = usage["seven_day"] as? [String: Any] {
            let raw = wk["utilization"] as? Double ?? 0
            NSLog("[ClaudeMonitor] seven_day utilization=%.4f", raw)
            // five_hour は 0〜100、seven_day は 0〜1 の可能性があるため正規化
            weeklyPct = raw > 1.0 ? Int(raw.rounded()) : Int((raw * 100).rounded())
            if let resetStr = wk["resets_at"] as? String {
                weeklyResetAt = formatter.date(from: resetStr)
            }
        }

        // five_hour キーが存在した = 正常レスポンスとみなす
        guard usage["five_hour"] != nil else {
            NSLog("[ClaudeMonitor] ❌ five_hour key missing. keys=%@", usage.keys.joined(separator: ","))
            return nil
        }
        return UsageData(
            sessionUsagePct: sessionPct,
            sessionResetSeconds: sessionResetSeconds,
            weeklyUsagePct: weeklyPct,
            weeklyResetAt: weeklyResetAt,
            fetchedAt: Date()
        )
    }

}

// MARK: - WKNavigationDelegate

extension ClaudeAPIService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            let url = webView.url?.absoluteString ?? ""
            NSLog("[ClaudeMonitor] ✓ finished: %@", url)

            if url.contains("login") || url.contains("signin") || url.contains("signup")
                || url.contains("auth.anthropic") || url.contains("auth0")
                || url == "https://claude.ai/" {
                NSLog("[ClaudeMonitor] needsLogin")
                self.delegate?.needsLogin()
                return
            }
            // ページロード完了後にAPIを直接呼ぶ
            self.evaluateUsageJS()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        NSLog("[ClaudeMonitor] ✗ nav failed: %@", error.localizedDescription)
        Task { @MainActor in self.delegate?.didFailToFetchUsageData(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        NSLog("[ClaudeMonitor] ✗ provisional failed: %@", error.localizedDescription)
        Task { @MainActor in self.delegate?.didFailToFetchUsageData(error) }
    }
}

import Cocoa
import WebKit

class LoginWindowController: NSWindowController {
    private var webView: WKWebView!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude — ログイン"
        window.center()
        self.init(window: window)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        webView = WKWebView(frame: window.contentRect(forFrameRect: window.frame), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self

        window.contentView = webView
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }
}

extension LoginWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }
        if url == "https://claude.ai/" || url.contains("/settings/usage") {
            close()
        }
    }
}

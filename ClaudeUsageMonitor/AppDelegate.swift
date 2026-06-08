import Cocoa
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var contentViewModel = ContentViewModel()
    private var apiService: ClaudeAPIService!
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var loginWindowController: LoginWindowController?

    private var refreshInterval: TimeInterval {
        get { TimeInterval(UserDefaults.standard.integer(forKey: "refreshInterval").nonzeroOrDefault(300)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "refreshInterval") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupAPIService()
        startRefreshTimer()

        Task {
            await UpdateService.shared.checkForUpdates()
            contentViewModel.updateAvailable = UpdateService.shared.latestVersion
        }
    }

    // MARK: - Setup

    private var statusBarView = StatusBarView()

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        // カスタムビューをボタンに埋め込む
        statusBarView.frame = NSRect(x: 0, y: 0,
                                     width: statusBarView.intrinsicContentSize.width,
                                     height: NSStatusBar.system.thickness)
        button.addSubview(statusBarView)
        button.frame = statusBarView.frame

        button.action = #selector(handleStatusBarClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 300)
        popover.behavior = .transient

        let hosting = NSHostingController(rootView: ContentView(viewModel: contentViewModel))
        popover.contentViewController = hosting

        contentViewModel.onRefresh = { [weak self] in self?.fetchUsage() }
        contentViewModel.onQuit = { NSApplication.shared.terminate(nil) }
    }

    private func setupAPIService() {
        apiService = ClaudeAPIService()
        apiService.delegate = self
        fetchUsage()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchUsage() }
        }
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if var data = self.contentViewModel.usageData {
                    if data.sessionResetSeconds > 0 {
                        data.sessionResetSeconds -= 1
                        self.contentViewModel.usageData = data
                    }
                    // stale になったタイミングでメニューバーも更新
                    self.updateStatusBar(data: data)
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp {
            let menu = buildContextMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        if let data = contentViewModel.usageData {
            menu.addItem(NSMenuItem(title: "Session: \(data.sessionUsagePct)%  Weekly: \(data.weeklyUsagePct)%", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }

        let intervalMenu = NSMenu()
        let intervals: [(String, Int)] = [
            ("30秒", 30), ("1分", 60), ("2分", 120), ("5分", 300), ("10分", 600)
        ]
        for (title, seconds) in intervals {
            let item = NSMenuItem(title: title, action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.tag = seconds
            item.target = self
            if Int(refreshInterval) == seconds { item.state = .on }
            intervalMenu.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "更新間隔", action: nil, keyEquivalent: "")
        menu.addItem(intervalItem)
        menu.setSubmenu(intervalMenu, for: intervalItem)

        menu.addItem(NSMenuItem(title: "今すぐ更新", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        refreshInterval = TimeInterval(sender.tag)
        startRefreshTimer()
    }

    @objc private func refreshNow() {
        fetchUsage()
    }

    private func fetchUsage() {
        contentViewModel.isLoading = true
        apiService.fetchUsage()
    }

    private func updateStatusBar(data: UsageData) {
        statusBarView.sessionPct = data.sessionUsagePct
        statusBarView.weeklyPct  = data.weeklyUsagePct
        statusBarView.isStale    = data.isStale
    }
}

extension AppDelegate: ClaudeAPIServiceDelegate {
    func didReceiveUsageData(_ data: UsageData) {
        NotificationService.shared.checkAndNotify(data: data)

        if let prev = contentViewModel.usageData,
           prev.sessionResetSeconds > 0 && data.sessionResetSeconds == 0 {
            NotificationService.shared.notifySessionReset()
        }

        contentViewModel.usageData = data
        contentViewModel.isLoading = false
        updateStatusBar(data: data)
        startCountdownTimer()
    }

    func didFailToFetchUsageData(_ error: Error) {
        contentViewModel.isLoading = false
    }

    func needsLogin() {
        contentViewModel.isLoading = false
        loginWindowController = LoginWindowController()
        loginWindowController?.showWindow(nil)
    }
}

private extension Int {
    func nonzeroOrDefault(_ default: Int) -> Int {
        self == 0 ? `default` : self
    }
}

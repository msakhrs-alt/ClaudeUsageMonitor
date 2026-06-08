import UserNotifications

class NotificationService {
    static let shared = NotificationService()

    private var notifiedAt80 = false
    private var notifiedAt90 = false
    private var notifiedAt100 = false

    private init() {
        notifiedAt80 = UserDefaults.standard.bool(forKey: "notifiedAt80")
        notifiedAt90 = UserDefaults.standard.bool(forKey: "notifiedAt90")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func checkAndNotify(data: UsageData) {
        let max = Swift.max(data.sessionUsagePct, data.weeklyUsagePct)

        if max >= 100 && !notifiedAt100 {
            send(title: "Claude Usage: 100%", body: "使用量が上限に達しました。")
            notifiedAt100 = true
        } else if max >= 90 && !notifiedAt90 {
            send(title: "Claude Usage: 90%", body: "使用量が90%を超えました。")
            notifiedAt90 = true
            UserDefaults.standard.set(true, forKey: "notifiedAt90")
        } else if max >= 80 && !notifiedAt80 {
            send(title: "Claude Usage: 80%", body: "使用量が80%を超えました。")
            notifiedAt80 = true
            UserDefaults.standard.set(true, forKey: "notifiedAt80")
        }

        if max < 80 {
            notifiedAt80 = false
            notifiedAt90 = false
            notifiedAt100 = false
            UserDefaults.standard.set(false, forKey: "notifiedAt80")
            UserDefaults.standard.set(false, forKey: "notifiedAt90")
        }
    }

    func notifySessionReset() {
        send(title: "Claude セッションリセット", body: "新しいセッションが開始されました。")
    }

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

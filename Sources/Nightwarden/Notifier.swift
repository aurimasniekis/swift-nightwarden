import AppKit
import NightwardenCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action {
        case restart, snooze, ignore, open
    }

    static let stuckCategory = "STUCK"
    static let watchCategory = "STUCK_WATCH"

    var onAction: (_ action: Action, _ service: String, _ pid: Int32) -> Void = { _, _, _ in }
    var onStatusChange: (UNAuthorizationStatus) -> Void = { _ in }

    /// nil when running outside an app bundle (e.g. `swift run`), where the center would crash.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil

    func setUp() {
        guard let center else { return }
        let restart = UNNotificationAction(identifier: "RESTART", title: "Restart", options: [])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze 1h", options: [])
        let ignore = UNNotificationAction(identifier: "IGNORE", title: "Ignore this PID", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.stuckCategory, actions: [restart, snooze, ignore], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.watchCategory, actions: [snooze, ignore], intentIdentifiers: []),
        ])
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        center?.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self?.onStatusChange(status) }
        }
    }

    static func stuckIdentifier(service: String, pid: Int32) -> String { "stuck.\(service).\(pid)" }

    func postStuck(_ flag: Flag, body: String, restartable: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "\(flag.service) looks stuck"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = restartable ? Self.stuckCategory : Self.watchCategory
        content.userInfo = ["service": flag.service, "pid": Int(flag.pid)]
        post(Self.stuckIdentifier(service: flag.service, pid: flag.pid), content)
    }

    func removeStuck(service: String, pid: Int32) {
        let id = Self.stuckIdentifier(service: service, pid: pid)
        center?.removeDeliveredNotifications(withIdentifiers: [id])
        center?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func postInfo(title: String, body: String, service: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let service { content.userInfo = ["service": service] }
        post("info.\(UUID().uuidString)", content)
    }

    func postTest() {
        postInfo(title: "Nightwarden test", body: "Notifications work. Choose the Alerts style so stuck warnings stay on screen.")
    }

    private func post(_ identifier: String, _ content: UNNotificationContent) {
        center?.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { NSLog("Nightwarden: notification failed: \(error)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let service = info["service"] as? String
        let pid = (info["pid"] as? Int).map(Int32.init) ?? 0
        let action: Action? = switch response.actionIdentifier {
        case "RESTART": .restart
        case "SNOOZE": .snooze
        case "IGNORE": .ignore
        case UNNotificationDefaultActionIdentifier: .open
        default: nil
        }
        Task { @MainActor in
            if let action, let service { self.onAction(action, service, pid) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

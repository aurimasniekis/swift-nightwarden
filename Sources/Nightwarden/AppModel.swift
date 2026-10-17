import Combine
import NightwardenCore
import SwiftUI
import UserNotifications

enum SidebarItem: Hashable {
    case overview, service(String), events, settings
}

/// Live state of one configured service.
struct ServiceStatus: Identifiable {
    var config: ServiceConfig
    var rule: Rule
    var instances: [ProcSample]
    var health: Health
    var flaggedPIDs: Set<Int32> = []

    var id: String { config.name }
    var name: String { config.name }
    var isRunning: Bool { !instances.isEmpty }
    /// kernel_task without root: CPU is derived, memory and lifetime CPU are unknown.
    var isEstimated: Bool { instances.contains(where: \.estimated) }
    var cpuKnown: Bool { instances.contains { $0.cpuPercent != nil } }
    var cpuTotal: Double { instances.compactMap(\.cpuPercent).reduce(0, +) }
    var rssTotal: UInt64 { instances.reduce(0) { $0 + $1.rssBytes } }
    /// The instance worth showing when only one fits: highest CPU, then memory.
    var primary: ProcSample? {
        instances.max { ($0.cpuPercent ?? 0, $0.rssBytes) < ($1.cpuPercent ?? 0, $1.rssBytes) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let configStore: ConfigStore
    let metrics: MetricsStore?

    @Published var config: Config {
        didSet {
            config = config.sanitized
            guard config != oldValue else { return }
            do { try configStore.save(config) } catch { lastError = "Couldn't save config: \(error.localizedDescription)" }
        }
    }
    @Published private(set) var statuses: [ServiceStatus] = []
    @Published private(set) var lastCheck: Date?
    /// Bumped after every poll so views re-query metrics.
    @Published private(set) var metricsVersion = 0
    @Published var selection: SidebarItem? = .overview
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published var lastError: String?

    // Wired up by AppDelegate.
    var restartAction: (_ service: String, _ pid: Int32) -> Void = { _, _ in }
    var checkNowAction: () -> Void = {}
    var testNotificationAction: () -> Void = {}
    var refreshNotificationStatusAction: () -> Void = {}

    init(configStore: ConfigStore) {
        self.configStore = configStore
        config = configStore.load()
        do {
            metrics = try MetricsStore(path: configStore.metricsURL.path)
        } catch {
            metrics = nil
            lastError = "Metrics disabled: \(error)"
        }
    }

    var anyFlagged: Bool { statuses.contains { $0.health == .flagged } }

    func status(named name: String) -> ServiceStatus? {
        statuses.first { $0.name == name }
    }

    func update(statuses: [ServiceStatus], at date: Date) {
        self.statuses = statuses
        lastCheck = date
        metricsVersion &+= 1
    }

    func metricsChanged() {
        metricsVersion &+= 1
    }

    func pauseAlerts(for seconds: TimeInterval?) {
        config.pausedUntil = seconds.map { Date().addingTimeInterval($0) }
    }

    func pauseAlertsIndefinitely() {
        config.pausedUntil = .distantFuture
    }

    func log(_ kind: EventKind, service: String, pid: Int32?, detail: String = "") {
        do {
            try metrics?.log(kind, service: service, pid: pid, detail: detail)
        } catch {
            lastError = "Couldn't log event: \(error)"
        }
        metricsChanged()
    }
}

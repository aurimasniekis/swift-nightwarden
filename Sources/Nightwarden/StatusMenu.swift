import AppKit
import NightwardenCore

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private var flagged: Bool?

    var showWindow: (SidebarItem?) -> Void = { _ in }
    var restart: (_ service: String, _ pid: Int32) -> Void = { _, _ in }
    var checkNow: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    /// Updates the icon; the menu itself is rebuilt each time it opens.
    func refresh() {
        let anyFlagged = model.anyFlagged
        guard anyFlagged != flagged else { return }
        flagged = anyFlagged
        let symbol = anyFlagged ? "exclamationmark.triangle.fill" : "moon.stars"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: anyFlagged ? "Nightwarden: service stuck" : "Nightwarden")
        image?.isTemplate = true
        item.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        let header = model.lastCheck.map { "Last check \(Format.duration(now.timeIntervalSince($0))) ago" } ?? "Checking…"
        menu.addItem(NSMenuItem(title: header, action: nil, keyEquivalent: ""))
        if let until = model.config.pausedUntil, until > now {
            let text = until == .distantFuture ? "Alerts paused" : "Alerts paused until \(until.formatted(date: .omitted, time: .shortened))"
            menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: ""))
        }
        if let error = model.lastError {
            menu.addItem(NSMenuItem(title: "⚠︎ \(error)", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())

        for status in model.statuses {
            menu.addItem(row(for: status))
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Check Now", key: "r") { [weak self] in self?.checkNow() })

        let pause = NSMenuItem(title: "Pause Alerts", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        pauseMenu.addItem(ActionItem("For 1 Hour") { [weak self] in self?.model.pauseAlerts(for: 3600) })
        pauseMenu.addItem(ActionItem("For 8 Hours") { [weak self] in self?.model.pauseAlerts(for: 8 * 3600) })
        pauseMenu.addItem(ActionItem("Until Resumed") { [weak self] in self?.model.pauseAlertsIndefinitely() })
        let resume = ActionItem("Resume") { [weak self] in self?.model.pauseAlerts(for: nil) }
        resume.isEnabled = model.config.alertsPaused(at: now)
        pauseMenu.autoenablesItems = false
        pauseMenu.addItem(.separator())
        pauseMenu.addItem(resume)
        pause.submenu = pauseMenu
        menu.addItem(pause)

        menu.addItem(ActionItem("Dashboard…") { [weak self] in self?.showWindow(.overview) })
        menu.addItem(ActionItem("Settings…", key: ",") { [weak self] in self?.showWindow(.settings) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Nightwarden", key: "q") { NSApp.terminate(nil) })
    }

    private func row(for status: ServiceStatus) -> NSMenuItem {
        let mark = status.health == .flagged ? "⚠︎ " : ""
        let title: String
        if !status.isRunning {
            title = "\(mark)\(status.name) — not running"
        } else if status.instances.count > 1 {
            title = "\(mark)\(status.name) ×\(status.instances.count) — \(cpuText(status)) · \(Format.bytes(status.rssTotal))"
        } else {
            let p = status.instances[0]
            let memory = p.estimated ? "est." : Format.bytes(p.rssBytes)
            title = "\(mark)\(status.name) — \(cpuText(status)) · \(memory) · up \(Format.duration(p.uptime))"
        }
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let name = status.name
        let canRestart = status.config.canRestart

        if status.instances.count == 1, canRestart {
            let pid = status.instances[0].pid
            sub.addItem(ActionItem("Restart…") { [weak self] in self?.restart(name, pid) })
        } else if status.instances.count > 1 {
            for p in status.instances {
                let flaggedMark = status.flaggedPIDs.contains(p.pid) ? "⚠︎ " : ""
                let instance = NSMenuItem(
                    title: "\(flaggedMark)PID \(p.pid) · uid \(p.uid) — \(p.cpuPercent.map(Format.percent) ?? "—%") · \(Format.bytes(p.rssBytes)) · up \(Format.duration(p.uptime))",
                    action: nil, keyEquivalent: "")
                if canRestart {
                    let pid = p.pid
                    let instanceMenu = NSMenu()
                    instanceMenu.addItem(ActionItem("Restart…") { [weak self] in self?.restart(name, pid) })
                    instance.submenu = instanceMenu
                }
                sub.addItem(instance)
            }
            sub.addItem(.separator())
        }
        sub.addItem(ActionItem("Show in Dashboard") { [weak self] in self?.showWindow(.service(name)) })
        row.submenu = sub
        return row
    }

    private func cpuText(_ status: ServiceStatus) -> String {
        status.cpuKnown ? Format.percent(status.cpuTotal) : "—%"
    }
}

import AppKit
import Combine
import NightwardenCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(configStore: ConfigStore())
    private let sampler = Sampler()
    private let detector = Detector()
    private let notifier = Notifier()
    private let restarter = Restarter()
    private var statusMenu: StatusMenu!
    private var window: MainWindowController!
    private var about: AboutWindowController!
    private let updateChecker = UpdateChecker()
    private var updateTimer: Timer?
    private var timer: Timer?
    private var polling = false
    private var restarting = Set<Int32>()
    private var lastPrune = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = MainWindowController(model: model)
        about = AboutWindowController(model: model)
        NSApp.mainMenu = makeMainMenu()
        statusMenu = StatusMenu(model: model)
        statusMenu.showWindow = { [weak self] item in self?.window.show(item) }
        statusMenu.restart = { [weak self] service, pid in self?.requestRestart(service: service, pid: pid, confirm: true) }
        statusMenu.checkNow = { [weak self] in self?.poll() }
        statusMenu.showAbout = { [weak self] in self?.about.show() }
        statusMenu.checkForUpdates = { [weak self] in self?.checkForUpdates(interactive: true) }
        statusMenu.showUpdate = { [weak self] in self?.showUpdateAlert() }

        model.restartAction = { [weak self] service, pid in self?.requestRestart(service: service, pid: pid, confirm: true) }
        model.checkNowAction = { [weak self] in self?.poll() }
        model.testNotificationAction = { [weak self] in self?.notifier.postTest() }
        model.refreshNotificationStatusAction = { [weak self] in self?.notifier.refreshStatus() }
        model.checkForUpdatesAction = { [weak self] in self?.checkForUpdates(interactive: true) }
        model.showUpdateAction = { [weak self] in self?.showUpdateAlert() }
        model.lastUpdateCheck = updateChecker.lastCheck

        notifier.onStatusChange = { [weak self] status in self?.model.notificationStatus = status }
        notifier.onAction = { [weak self] action, service, pid in self?.handle(action, service: service, pid: pid) }
        notifier.onOpenUpdate = { [weak self] in self?.showUpdateAlert() }
        notifier.setUp()

        model.$config.map(\.pollSeconds).removeDuplicates()
            .sink { [weak self] seconds in self?.schedule(every: seconds) }
            .store(in: &cancellables)

        if let i = CommandLine.arguments.firstIndex(of: "--show") {
            let page = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "overview"
            if page == "about" { about.show() } else { window.show(Self.sidebarItem(page)) }
        }

        scheduleUpdateChecks()
        poll()
        // A second sample soon after launch so CPU rates show up without waiting a full interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.poll() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        notifier.refreshStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Polling

    private func schedule(every seconds: Double) {
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = min(seconds * 0.1, 5)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        guard !polling else { return }
        polling = true
        Task {
            let rows = await ProcessList.snapshotAsync()
            // Read host CPU right after ps so the kernel_task estimate covers the same interval.
            let hostBusy = HostCPU.busySeconds()
            polling = false
            guard let rows else {
                model.lastError = "ps failed"
                return
            }
            process(rows, hostBusy: hostBusy, at: Date())
        }
    }

    private func process(_ rows: [PSRow], hostBusy: Double?, at now: Date) {
        let config = model.config
        let active = config.activeServices
        let rules = config.rules
        let samples = sampler.ingest(rows, services: Set(rules.keys), at: now, hostBusy: hostBusy)
        detector.renotifyInterval = config.renotifyMinutes * 60
        let events = detector.update(samples, rules: rules, now: now, alertsPaused: config.alertsPaused(at: now))

        let byService = Dictionary(grouping: samples, by: \.service)
        let metricRows = active.compactMap { s in byService[s.name].flatMap { ServiceSampleRow.aggregate(service: s.name, $0) } }
        do {
            try model.metrics?.record(metricRows, at: now)
            if now.timeIntervalSince(lastPrune) >= 3600 {
                try model.metrics?.prune(now: now)
                lastPrune = now
            }
        } catch {
            model.lastError = "Metrics: \(error)"
        }

        for event in events { handle(event, rules: rules, now: now) }

        let statuses = active.map { service -> ServiceStatus in
            let instances = (byService[service.name] ?? []).sorted { $0.pid < $1.pid }
            let health = instances.map { detector.health(pid: $0.pid) }.max() ?? .ok
            let flagged = Set(instances.map(\.pid).filter { detector.health(pid: $0) == .flagged })
            return ServiceStatus(config: service, rule: config.rule(for: service), instances: instances,
                                 health: health, flaggedPIDs: flagged)
        }
        model.update(statuses: statuses, at: now)
        statusMenu.refresh()
    }

    private func handle(_ event: DetectorEvent, rules: [String: Rule], now: Date) {
        switch event {
        case .flagged(let flag):
            let s = flag.sample
            var detail = "\(flag.reason): \(s.cpuPercent.map(Format.percent) ?? "?%") CPU, \(Format.bytes(s.rssBytes)) RSS"
            if flag.cpuStuck { detail += ", high for \(Format.duration(flag.stuckFor(at: now)))" }
            model.log(.flagged, service: flag.service, pid: flag.pid, detail: detail)

        case .notify(let flag):
            let rule = rules[flag.service]
            Task {
                let footprint = await Footprint.measure(pid: flag.pid)
                let body = Format.stuckBody(flag, memoryBytes: footprint ?? flag.sample.rssBytes,
                                            limitBytes: rule?.memoryLimitBytes, now: now)
                notifier.postStuck(flag, body: body, restartable: rule?.restartable ?? false)
                model.log(.notified, service: flag.service, pid: flag.pid, detail: body)
            }

        case .cleared(let service, let pid):
            notifier.removeStuck(service: service, pid: pid)
            model.log(.cleared, service: service, pid: pid)

        case .respawned(let service, let oldPID, let newPID):
            notifier.removeStuck(service: service, pid: oldPID)
            model.log(.respawned, service: service, pid: newPID, detail: "PID \(oldPID) → \(newPID)")
        }
    }

    // MARK: Actions

    private func handle(_ action: Notifier.Action, service: String, pid: Int32) {
        switch action {
        case .restart:
            requestRestart(service: service, pid: pid, confirm: false)
        case .snooze:
            detector.snooze(pid: pid, until: Date().addingTimeInterval(3600))
            model.log(.snoozed, service: service, pid: pid, detail: "1h")
        case .ignore:
            detector.ignore(pid: pid)
            model.log(.ignored, service: service, pid: pid)
        case .open:
            window.show(.service(service))
        }
    }

    /// `confirm` is false when the click came from the notification's Restart button.
    func requestRestart(service: String, pid: Int32, confirm: Bool) {
        guard let status = model.status(named: service), status.config.canRestart else {
            alert("\(service) can't be restarted", "It is watch-only. Enable “Restartable” in Settings if you're sure.")
            return
        }
        guard let target = status.instances.first(where: { $0.pid == pid }) ?? detector.states[pid]?.lastSample else {
            alert("\(service) (PID \(pid)) is gone", "It may already have been restarted.")
            return
        }
        guard !restarting.contains(pid) else { return }
        if confirm {
            let a = NSAlert()
            a.messageText = "Restart \(service) (PID \(pid))?"
            a.informativeText = "Nightwarden sends SIGTERM (then SIGKILL after 3 s). System daemons are respawned by launchd."
                + (target.uid == getuid() ? "" : " You'll be asked for an administrator password.")
            a.addButton(withTitle: "Restart")
            a.addButton(withTitle: "Cancel")
            bringToFront()
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        restarting.insert(pid)
        Task {
            await performRestart(target)
            restarting.remove(pid)
        }
    }

    private func performRestart(_ target: ProcSample) async {
        let service = target.service
        let before = await Footprint.measure(pid: target.pid) ?? target.rssBytes
        model.log(.restartRequested, service: service, pid: target.pid, detail: "\(Format.bytes(before)) before")
        detector.expectRestart(service: service, until: Date().addingTimeInterval(60))

        switch await restarter.restart(target) {
        case .respawned(let fresh):
            let after = await Footprint.measure(pid: fresh.pid) ?? fresh.rssBytes
            notifier.removeStuck(service: service, pid: target.pid)
            notifier.postInfo(title: "\(service) restarted",
                              body: "PID \(fresh.pid), \(Format.bytes(after)) (was \(Format.bytes(before)))", service: service)
            model.log(.restarted, service: service, pid: fresh.pid,
                      detail: "PID \(target.pid) → \(fresh.pid) · \(Format.bytes(before)) → \(Format.bytes(after))")
        case .notRespawned:
            notifier.removeStuck(service: service, pid: target.pid)
            notifier.postInfo(title: "\(service) stopped",
                              body: "PID \(target.pid) exited (was \(Format.bytes(before))); nothing respawned it within \(Restarter.respawnTimeout) s.",
                              service: service)
            model.log(.restarted, service: service, pid: target.pid,
                      detail: "PID \(target.pid) → none · \(Format.bytes(before)) freed, no respawn within \(Restarter.respawnTimeout) s")
        case .cancelled:
            model.log(.restartCancelled, service: service, pid: target.pid, detail: "Admin authentication cancelled")
        case .failed(let message):
            model.log(.restartFailed, service: service, pid: target.pid, detail: message)
            alert("Couldn't restart \(service)", message)
        }
        poll()
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        bringToFront()
        a.runModal()
    }

    /// `--show overview|events|settings|<service>` opens the window at launch (`--show about` the About window).
    private static func sidebarItem(_ page: String) -> SidebarItem {
        switch page {
        case "overview": return .overview
        case "events": return .events
        case "settings": return .settings
        default: return .service(page)
        }
    }

    // MARK: Updates

    /// Automatic checks: shortly after launch, then hourly ticks that only hit the network once a day.
    private func scheduleUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.automaticUpdateCheck() }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.automaticUpdateCheck() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    private func automaticUpdateCheck() {
        guard model.config.checkForUpdates, updateChecker.isDue else { return }
        checkForUpdates(interactive: false)
    }

    /// `interactive` checks report every outcome; automatic ones only notify about a new version, once.
    func checkForUpdates(interactive: Bool) {
        guard !model.checkingForUpdates else { return }
        model.checkingForUpdates = true
        Task {
            let result = await updateChecker.check()
            model.checkingForUpdates = false
            model.lastUpdateCheck = updateChecker.lastCheck
            switch result {
            case .available(let release):
                model.availableUpdate = release
                statusMenu.refresh()
                if interactive {
                    showUpdateAlert()
                } else if updateChecker.shouldNotify(about: release) {
                    notifier.postUpdate(release)
                    updateChecker.markNotified(release)
                }
            case .upToDate(let latest):
                model.availableUpdate = nil
                if interactive {
                    alert("You're up to date",
                          latest == nil ? "No releases have been published yet."
                                        : "\(AppInfo.name) \(AppInfo.version) is the latest version.")
                }
            case .failed(let message):
                if interactive { alert("Couldn't check for updates", message) }
            }
        }
    }

    private func showUpdateAlert() {
        guard let release = model.availableUpdate else {
            checkForUpdates(interactive: true)
            return
        }
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        a.messageText = "\(AppInfo.name) \(release.version?.description ?? release.tagName) is available"
        var text = "You have \(AppInfo.version)."
        if let notes = release.notesExcerpt() { text += "\n\n" + notes }
        a.informativeText = text
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Release Notes")
        a.addButton(withTitle: "Later")
        bringToFront()
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(release.downloadURL)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.htmlURL)
        default: break
        }
    }

    // MARK: Main menu (used while a window is open)

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(ActionItem("About \(AppInfo.name)") { [weak self] in self?.about.show() })
        appMenu.addItem(ActionItem("Check for Updates…") { [weak self] in self?.checkForUpdates(interactive: true) })
        appMenu.addItem(.separator())
        appMenu.addItem(ActionItem("Settings…", key: ",") { [weak self] in self?.window.show(.settings) })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: AppInfo.name)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        windowMenu.addItem(ActionItem("Dashboard") { [weak self] in self?.window.show(nil) })
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        let help = NSMenu(title: "Help")
        help.addItem(ActionItem("\(AppInfo.name) on GitHub") { NSWorkspace.shared.open(AppInfo.repositoryURL) })
        help.addItem(ActionItem("Release Notes") { NSWorkspace.shared.open(AppInfo.releasesURL) })
        help.addItem(ActionItem("Report an Issue…") { NSWorkspace.shared.open(AppInfo.newIssueURL) })
        main.addItem(submenu: help, title: "Help")
        NSApp.helpMenu = help
        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

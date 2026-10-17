import AppKit
import NightwardenCore

/// `--print`: two samples 3 s apart, print a table of watched services, exit.
func printTable() -> Int32 {
    let store = ConfigStore()
    let config = store.load()
    let rules = config.rules
    let sampler = Sampler()
    guard let first = try? ProcessList.snapshot() else { return 1 }
    _ = sampler.ingest(first, services: Set(rules.keys), at: Date(), hostBusy: HostCPU.busySeconds())
    Thread.sleep(forTimeInterval: 3)
    guard let second = try? ProcessList.snapshot() else { return 1 }
    let samples = sampler.ingest(second, services: Set(rules.keys), at: Date(), hostBusy: HostCPU.busySeconds())

    func user(_ uid: UInt32) -> String {
        guard let pw = getpwuid(uid) else { return String(uid) }
        return String(cString: pw.pointee.pw_name)
    }
    func pad(_ s: String, _ n: Int, right: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, n - s.count))
        return right ? fill + s : s + fill
    }

    print("Config: \(store.url.path)")
    print([pad("SERVICE", 16), pad("PID", 7, right: true), " ", pad("USER", 20), pad("CPU%", 6, right: true),
           pad("RSS", 9, right: true), pad("UP", 9, right: true), pad("CPU TIME", 10, right: true), "  RULE"].joined())
    for service in config.activeServices {
        let rule = rules[service.name]!
        let ruleText = "\(Format.percent(rule.cpuPercent))/\(Format.duration(rule.cpuMinutes * 60))"
            + (rule.memoryLimitBytes.map { ", \(Format.bytes($0))" } ?? "")
            + (rule.restartable ? "" : ", watch-only")
        let instances = samples.filter { $0.service == service.name }.sorted { $0.pid < $1.pid }
        if instances.isEmpty {
            print([pad(service.name, 16), pad("-", 7, right: true), " ", pad("", 20), pad("", 6), pad("", 9), pad("", 9),
                   pad("", 10), "  \(ruleText)  (not running)"].joined())
        }
        for p in instances {
            print([pad(service.name, 16), pad(String(p.pid), 7, right: true), " ", pad(user(p.uid), 20),
                   pad(p.cpuPercent.map { String(format: "%.1f", $0) } ?? "?", 6, right: true),
                   pad(p.estimated ? "-" : Format.bytes(p.rssBytes), 9, right: true), pad(Format.duration(p.uptime), 9, right: true),
                   pad(p.estimated ? "-" : Format.cpuTime(p.cpuSeconds), 10, right: true),
                   "  \(ruleText)\(p.estimated ? "  (CPU estimated)" : "")"].joined())
        }
    }
    return 0
}

if CommandLine.arguments.contains("--print") {
    exit(printTable())
}

MainActor.assumeIsolated {
    // One instance only; a second launch (e.g. LaunchAgent + `make run`) just exits cleanly.
    if let id = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

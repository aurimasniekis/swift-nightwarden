import Foundation

/// Effective thresholds for one service after applying defaults.
public struct Rule: Equatable, Sendable {
    public var cpuPercent: Double
    public var cpuMinutes: Double
    public var memoryLimitBytes: UInt64?
    public var restartable: Bool

    public init(cpuPercent: Double, cpuMinutes: Double, memoryLimitBytes: UInt64?, restartable: Bool) {
        self.cpuPercent = cpuPercent
        self.cpuMinutes = cpuMinutes
        self.memoryLimitBytes = memoryLimitBytes
        self.restartable = restartable
    }
}

public struct ServiceConfig: Codable, Identifiable, Hashable, Sendable {
    /// Only used to identify rows in the UI; not persisted.
    public var id = UUID()
    public var name: String
    public var enabled: Bool
    public var restartable: Bool
    /// nil means "use the default".
    public var cpuPercent: Double?
    public var cpuMinutes: Double?
    public var memoryLimitMB: Double?

    enum CodingKeys: String, CodingKey {
        case name, enabled, restartable, cpuPercent, cpuMinutes, memoryLimitMB
    }

    public init(name: String, enabled: Bool = true, restartable: Bool,
                cpuPercent: Double? = nil, cpuMinutes: Double? = nil, memoryLimitMB: Double? = nil) {
        self.name = name
        self.enabled = enabled
        self.restartable = restartable
        self.cpuPercent = cpuPercent
        self.cpuMinutes = cpuMinutes
        self.memoryLimitMB = memoryLimitMB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        restartable = try c.decodeIfPresent(Bool.self, forKey: .restartable) ?? false
        cpuPercent = try c.decodeIfPresent(Double.self, forKey: .cpuPercent)
        cpuMinutes = try c.decodeIfPresent(Double.self, forKey: .cpuMinutes)
        memoryLimitMB = try c.decodeIfPresent(Double.self, forKey: .memoryLimitMB)
    }

    /// Never restartable, whatever the config says.
    public var isProtected: Bool { Config.protectedServices.contains(name) }
    public var canRestart: Bool { restartable && !isProtected }
}

public struct Config: Codable, Equatable, Sendable {
    public var pollSeconds: Double = 30
    public var defaultCPUPercent: Double = 80
    public var defaultCPUMinutes: Double = 10
    public var renotifyMinutes: Double = 60
    public var pausedUntil: Date?
    public var services: [ServiceConfig] = Config.defaultServices

    public static let protectedServices: Set<String> = ["WindowServer", "kernel_task", "cfprefsd"]
    public static let pollRange: ClosedRange<Double> = 10...300

    public static let defaultServices: [ServiceConfig] = [
        ServiceConfig(name: "fseventsd", restartable: true, memoryLimitMB: 2048),
        ServiceConfig(name: "mds", restartable: true, cpuPercent: 80, cpuMinutes: 30, memoryLimitMB: 3072),
        ServiceConfig(name: "mds_stores", restartable: true, cpuPercent: 80, cpuMinutes: 30, memoryLimitMB: 4096),
        ServiceConfig(name: "corespotlightd", restartable: true, cpuPercent: 80, cpuMinutes: 30, memoryLimitMB: 2048),
        ServiceConfig(name: "photoanalysisd", restartable: true, cpuPercent: 80, cpuMinutes: 30, memoryLimitMB: 3072),
        ServiceConfig(name: "mediaanalysisd", restartable: true, cpuPercent: 80, cpuMinutes: 30, memoryLimitMB: 3072),
        ServiceConfig(name: "cloudd", restartable: true, memoryLimitMB: 2048),
        ServiceConfig(name: "bird", restartable: true, memoryLimitMB: 2048),
        ServiceConfig(name: "trustd", restartable: true, memoryLimitMB: 1024),
        ServiceConfig(name: "syspolicyd", restartable: true, memoryLimitMB: 1024),
        ServiceConfig(name: "coreaudiod", restartable: true, memoryLimitMB: 1024),
        ServiceConfig(name: "Finder", restartable: true, memoryLimitMB: 3072),
        ServiceConfig(name: "distnoted", restartable: false, memoryLimitMB: 512),
        ServiceConfig(name: "cfprefsd", restartable: false, memoryLimitMB: 1024),
        ServiceConfig(name: "WindowServer", restartable: false, cpuPercent: 80, cpuMinutes: 15, memoryLimitMB: 6144),
        ServiceConfig(name: "kernel_task", restartable: false, cpuPercent: 300, cpuMinutes: 15),
    ]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case pollSeconds, defaultCPUPercent, defaultCPUMinutes, renotifyMinutes, pausedUntil, services
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? pollSeconds
        defaultCPUPercent = try c.decodeIfPresent(Double.self, forKey: .defaultCPUPercent) ?? defaultCPUPercent
        defaultCPUMinutes = try c.decodeIfPresent(Double.self, forKey: .defaultCPUMinutes) ?? defaultCPUMinutes
        renotifyMinutes = try c.decodeIfPresent(Double.self, forKey: .renotifyMinutes) ?? renotifyMinutes
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        services = try c.decodeIfPresent([ServiceConfig].self, forKey: .services) ?? services
    }

    /// Values clamped to sane ranges.
    public var sanitized: Config {
        var c = self
        c.pollSeconds = min(max(pollSeconds, Self.pollRange.lowerBound), Self.pollRange.upperBound)
        c.defaultCPUPercent = max(defaultCPUPercent, 1)
        c.defaultCPUMinutes = max(defaultCPUMinutes, 0.5)
        c.renotifyMinutes = max(renotifyMinutes, 1)
        return c
    }

    public func rule(for service: ServiceConfig) -> Rule {
        Rule(cpuPercent: service.cpuPercent ?? defaultCPUPercent,
             cpuMinutes: service.cpuMinutes ?? defaultCPUMinutes,
             memoryLimitBytes: service.memoryLimitMB.map { UInt64(max($0, 0) * 1024 * 1024) },
             restartable: service.canRestart)
    }

    /// Enabled, uniquely named services in config order.
    public var activeServices: [ServiceConfig] {
        var seen = Set<String>()
        return services.filter { $0.enabled && !$0.name.isEmpty && seen.insert($0.name).inserted }
    }

    public var rules: [String: Rule] {
        Dictionary(uniqueKeysWithValues: activeServices.map { ($0.name, rule(for: $0)) })
    }

    public func alertsPaused(at now: Date) -> Bool {
        pausedUntil.map { now < $0 } ?? false
    }
}

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL = ConfigStore.defaultURL()) {
        self.url = url
    }

    /// `NIGHTWARDEN_CONFIG` overrides the location (for testing).
    public static func defaultURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["NIGHTWARDEN_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Nightwarden/config.json")
    }

    /// Metrics live next to the config, so a test config gets its own database.
    public var directory: URL { url.deletingLastPathComponent() }
    public var metricsURL: URL { directory.appendingPathComponent("metrics.sqlite") }

    /// Loads the config; a missing file is seeded with defaults, an unreadable one is set aside.
    public func load() -> Config {
        guard let data = try? Data(contentsOf: url) else {
            let config = Config()
            try? save(config)
            return config
        }
        do {
            return try Self.decoder.decode(Config.self, from: data).sanitized
        } catch {
            let backup = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            let config = Config()
            try? save(config)
            return config
        }
    }

    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(config).write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

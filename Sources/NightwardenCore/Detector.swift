import Foundation

public enum Health: Int, Comparable, Sendable {
    case ok, elevated, flagged

    public static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
}

/// A PID that has crossed its stuck rule.
public struct Flag: Equatable, Sendable {
    public var sample: ProcSample
    public var cpuStuck: Bool
    public var memoryStuck: Bool
    public var highSince: Date?
    public var flaggedSince: Date

    public var pid: Int32 { sample.pid }
    public var service: String { sample.service }

    /// How long the CPU has been pinned, or how long it's been over the memory limit.
    public func stuckFor(at now: Date) -> TimeInterval {
        now.timeIntervalSince(cpuStuck ? (highSince ?? flaggedSince) : flaggedSince)
    }

    public var reason: String {
        switch (cpuStuck, memoryStuck) {
        case (true, true): return "CPU and memory"
        case (true, false): return "CPU"
        default: return "memory"
        }
    }
}

public enum DetectorEvent: Equatable, Sendable {
    case flagged(Flag)
    case notify(Flag)
    case cleared(service: String, pid: Int32)
    case respawned(service: String, oldPID: Int32, newPID: Int32)
}

/// Per-PID stuck detection. Feed it every poll's samples; it returns what changed.
public final class Detector {
    public struct State: Equatable, Sendable {
        public var command: String
        public var lastSample: ProcSample
        public var highSince: Date?
        public var belowCount = 0
        public var memHighCount = 0
        public var flaggedSince: Date?
        public var flag: Flag?
        public var lastNotified: Date?
        public var snoozedUntil: Date?
        public var ignored = false

        public var health: Health {
            if flaggedSince != nil { return .flagged }
            if highSince != nil || memHighCount > 0 { return .elevated }
            return .ok
        }
    }

    public private(set) var states: [Int32: State] = [:]
    public var renotifyInterval: TimeInterval = 3600
    private var lastPIDs: [String: Set<Int32>] = [:]
    private var restartExpected: [String: Date] = [:]

    public init() {}

    public var flags: [Flag] { states.values.compactMap(\.flag) }

    public func health(pid: Int32) -> Health { states[pid]?.health ?? .ok }

    public func update(_ samples: [ProcSample], rules: [String: Rule], now: Date, alertsPaused: Bool = false) -> [DetectorEvent] {
        var events: [DetectorEvent] = []
        var next: [Int32: State] = [:]
        var pidsByService: [String: Set<Int32>] = [:]

        for sample in samples {
            guard let rule = rules[sample.service] else { continue }
            pidsByService[sample.service, default: []].insert(sample.pid)

            var st: State
            if var old = states[sample.pid], old.command == sample.command {
                old.lastSample = sample
                st = old
            } else {
                st = State(command: sample.command, lastSample: sample)
            }

            if let cpu = sample.cpuPercent {
                if cpu >= rule.cpuPercent {
                    if st.highSince == nil { st.highSince = now }
                    st.belowCount = 0
                } else if st.highSince != nil {
                    st.belowCount += 1
                    if st.belowCount >= 2 {
                        st.highSince = nil
                        st.belowCount = 0
                    }
                }
            }

            if let limit = rule.memoryLimitBytes, sample.rssBytes >= limit {
                st.memHighCount += 1
            } else {
                st.memHighCount = 0
            }

            let cpuStuck = st.highSince.map { now.timeIntervalSince($0) >= rule.cpuMinutes * 60 } ?? false
            let memoryStuck = st.memHighCount >= 2

            if cpuStuck || memoryStuck {
                let isNew = st.flaggedSince == nil
                let since = st.flaggedSince ?? now
                st.flaggedSince = since
                let flag = Flag(sample: sample, cpuStuck: cpuStuck, memoryStuck: memoryStuck,
                                highSince: st.highSince, flaggedSince: since)
                st.flag = flag
                if isNew { events.append(.flagged(flag)) }

                let snoozed = st.snoozedUntil.map { now < $0 } ?? false
                let due = st.lastNotified.map { now.timeIntervalSince($0) >= renotifyInterval } ?? true
                if !alertsPaused && !st.ignored && !snoozed && due {
                    st.lastNotified = now
                    events.append(.notify(flag))
                }
            } else if st.flaggedSince != nil {
                st.flaggedSince = nil
                st.flag = nil
                st.lastNotified = nil
                events.append(.cleared(service: sample.service, pid: sample.pid))
            }
            next[sample.pid] = st
        }

        restartExpected = restartExpected.filter { $0.value > now }
        for (service, current) in pidsByService {
            // Only single-instance services: multi-instance ones churn PIDs normally.
            if let previous = lastPIDs[service], previous.count == 1, current.count == 1, previous != current,
               restartExpected[service] == nil, let old = previous.first, let new = current.first {
                events.append(.respawned(service: service, oldPID: old, newPID: new))
            }
            lastPIDs[service] = current
        }

        states = next
        return events
    }

    public func snooze(pid: Int32, until: Date) {
        states[pid]?.snoozedUntil = until
    }

    public func ignore(pid: Int32) {
        states[pid]?.ignored = true
    }

    /// Suppresses the `respawned` event for a restart we initiated.
    public func expectRestart(service: String, until: Date) {
        restartExpected[service] = until
    }
}

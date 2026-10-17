import Foundation

/// A watched process at one point in time.
public struct ProcSample: Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var uid: UInt32
    public var service: String
    public var command: String
    public var rssBytes: UInt64
    /// CPU % over the interval since the previous sample; nil the first time a PID is seen.
    public var cpuPercent: Double?
    public var cpuSeconds: Double
    public var uptime: Double
    /// Derived rather than measured (kernel_task without root): no RSS or lifetime CPU.
    public var estimated: Bool

    public var id: Int32 { pid }

    public init(pid: Int32, uid: UInt32, service: String, command: String, rssBytes: UInt64,
                cpuPercent: Double?, cpuSeconds: Double, uptime: Double, estimated: Bool = false) {
        self.pid = pid
        self.uid = uid
        self.service = service
        self.command = command
        self.rssBytes = rssBytes
        self.cpuPercent = cpuPercent
        self.cpuSeconds = cpuSeconds
        self.uptime = uptime
        self.estimated = estimated
    }
}

/// Turns successive `ps` snapshots into CPU rates (Δcputime / Δwall) per PID.
public final class Sampler {
    public static let kernelTask = "kernel_task"

    private struct Previous {
        var command: String
        var cpuSeconds: Double
    }

    private var previous: [Int32: Previous] = [:]
    private var previousAt: Date?
    private var previousHostBusy: Double?

    public init() {}

    /// `hostBusy` is cumulative busy CPU seconds for the whole machine (see `HostCPU`). When given and
    /// `kernel_task` is watched but invisible to `ps` (PID 0 needs root), its CPU is estimated as
    /// host busy time minus the CPU time of every visible process.
    public func ingest(_ rows: [PSRow], services: Set<String>, at now: Date, hostBusy: Double? = nil) -> [ProcSample] {
        let wall = previousAt.map { now.timeIntervalSince($0) } ?? 0
        var next: [Int32: Previous] = [:]
        var samples: [ProcSample] = []
        var visibleCPU = 0.0
        for row in rows {
            var used: Double?
            // Same PID but a different command means the PID was reused.
            if let prev = previous[row.pid], prev.command == row.command {
                if row.cpuSeconds >= prev.cpuSeconds { used = row.cpuSeconds - prev.cpuSeconds }
            } else if wall > 0, row.elapsedSeconds <= wall + 1 {
                visibleCPU += row.cpuSeconds  // started within the interval
            }
            visibleCPU += used ?? 0
            next[row.pid] = Previous(command: row.command, cpuSeconds: row.cpuSeconds)

            let name = row.name
            guard services.contains(name) else { continue }
            let cpu = wall > 0 ? used.map { $0 / wall * 100 } : nil
            samples.append(ProcSample(pid: row.pid, uid: row.uid, service: name, command: row.command,
                                      rssBytes: row.rssBytes, cpuPercent: cpu,
                                      cpuSeconds: row.cpuSeconds, uptime: row.elapsedSeconds))
        }

        if let hostBusy, services.contains(Self.kernelTask), !samples.contains(where: { $0.service == Self.kernelTask }) {
            var cpu: Double?
            if let before = previousHostBusy, wall > 0 {
                cpu = max(0, (hostBusy - before - visibleCPU) / wall * 100)
            }
            samples.append(ProcSample(pid: 0, uid: 0, service: Self.kernelTask, command: Self.kernelTask, rssBytes: 0,
                                      cpuPercent: cpu, cpuSeconds: 0, uptime: HostCPU.uptime(at: now), estimated: true))
        }

        previous = next
        previousAt = now
        previousHostBusy = hostBusy
        return samples
    }
}

public enum HostCPU {
    /// Cumulative user + system + nice CPU seconds across all cores.
    public static func busySeconds() -> Double? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let ticks = Double(t.0) + Double(t.1) + Double(t.3)  // user, system, (idle), nice
        return ticks / Double(sysconf(_SC_CLK_TCK))
    }

    /// Seconds since boot, including sleep.
    public static func uptime(at now: Date) -> Double {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return now.timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }
}

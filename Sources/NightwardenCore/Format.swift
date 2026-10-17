import Foundation

public enum Format {
    /// "45s", "12m", "3h 5m", "75d 2h".
    public static func duration(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m" }
        if t < 86_400 {
            let h = t / 3600, m = (t % 3600) / 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        let d = t / 86_400, h = (t % 86_400) / 3600
        return h == 0 ? "\(d)d" : "\(d)d \(h)h"
    }

    /// "512 KB", "11 MB", "2 GB", "15.2 GB" (binary units, as `top` reports).
    public static func bytes(_ bytes: UInt64) -> String {
        let v = Double(bytes)
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if v >= gb {
            let g = v / gb
            if g >= 100 { return String(format: "%.0f GB", g) }
            let s = String(format: "%.1f", g)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + " GB"
        }
        if v >= mb { return String(format: "%.0f MB", v / mb) }
        if v >= kb { return String(format: "%.0f KB", v / kb) }
        return "\(bytes) B"
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// "246h CPU lifetime (14% avg)".
    public static func lifetimeCPU(cpuSeconds: Double, uptime: Double) -> String {
        "\(cpuTime(cpuSeconds)) CPU lifetime (\(percent(averageCPU(cpuSeconds: cpuSeconds, uptime: uptime))) avg)"
    }

    /// Whole hours once past an hour ("246h"), otherwise a short duration.
    public static func cpuTime(_ seconds: Double) -> String {
        seconds >= 3600 ? "\(Int(seconds / 3600))h" : duration(seconds)
    }

    public static func averageCPU(cpuSeconds: Double, uptime: Double) -> Double {
        uptime > 0 ? cpuSeconds / uptime * 100 : 0
    }

    /// "98% CPU for 12m · 15.2 GB memory · up 75d 2h · 246h CPU lifetime (14% avg)".
    public static func stuckBody(_ flag: Flag, memoryBytes: UInt64, limitBytes: UInt64?, now: Date) -> String {
        let s = flag.sample
        let cpu = s.cpuPercent.map(percent) ?? "?%"
        var memory = "\(bytes(memoryBytes)) memory"
        if flag.memoryStuck, let limit = limitBytes { memory += " (limit \(bytes(limit)))" }
        var parts: [String]
        if flag.cpuStuck {
            parts = ["\(cpu) CPU for \(duration(flag.stuckFor(at: now)))", memory]
        } else {
            parts = [memory, "\(cpu) CPU"]
        }
        parts.append("up \(duration(s.uptime))")
        if !s.estimated { parts.append(lifetimeCPU(cpuSeconds: s.cpuSeconds, uptime: s.uptime)) }
        return parts.joined(separator: " · ")
    }
}

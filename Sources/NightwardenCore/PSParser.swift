import Foundation

/// One line of `ps -axo pid=,uid=,rss=,time=,etime=,comm=`.
public struct PSRow: Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var rssBytes: UInt64
    public var cpuSeconds: Double
    public var elapsedSeconds: Double
    /// Full executable path as reported by `comm` (may contain spaces).
    public var command: String

    public init(pid: Int32, uid: UInt32, rssBytes: UInt64, cpuSeconds: Double, elapsedSeconds: Double, command: String) {
        self.pid = pid
        self.uid = uid
        self.rssBytes = rssBytes
        self.cpuSeconds = cpuSeconds
        self.elapsedSeconds = elapsedSeconds
        self.command = command
    }

    /// Basename of `command`, which is what services are matched against.
    public var name: String { PSParser.basename(command) }
}

public enum PSParser {
    public static let arguments = ["-axo", "pid=,uid=,rss=,time=,etime=,comm="]

    public static func parse(_ output: String) -> [PSRow] {
        output.split(whereSeparator: \.isNewline).compactMap { parseLine($0) }
    }

    /// Five whitespace-separated fields, then `comm` is the rest of the line.
    public static func parseLine(_ line: some StringProtocol) -> PSRow? {
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        var rest = Substring(line)
        var fields: [Substring] = []
        for _ in 0..<5 {
            rest = rest.drop(while: isBlank)
            guard let end = rest.firstIndex(where: isBlank) else { return nil }
            fields.append(rest[..<end])
            rest = rest[end...]
        }
        var command = rest.drop(while: isBlank)
        while let last = command.last, isBlank(last) { command = command.dropLast() }
        guard !command.isEmpty,
              let pid = Int32(fields[0]),
              let uid = UInt32(fields[1]),
              let rssKB = UInt64(fields[2]),
              let cpu = duration(fields[3]),
              let elapsed = duration(fields[4])
        else { return nil }
        return PSRow(pid: pid, uid: uid, rssBytes: rssKB * 1024, cpuSeconds: cpu,
                     elapsedSeconds: elapsed, command: String(command))
    }

    /// Parses `ps` time fields: "ss", "mm:ss", "hh:mm:ss", optionally prefixed by "d-",
    /// with fractional seconds ("1687:10.26"). Minutes may be arbitrarily large.
    public static func duration(_ text: some StringProtocol) -> Double? {
        var clock = Substring(text)
        var days = 0.0
        if let dash = clock.firstIndex(of: "-") {
            guard let d = Double(clock[..<dash]), d >= 0 else { return nil }
            days = d
            clock = clock[clock.index(after: dash)...]
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return days * 86_400 + total
    }

    public static func basename(_ command: String) -> String {
        guard let slash = command.lastIndex(of: "/") else { return command }
        return String(command[command.index(after: slash)...])
    }

    /// Parses `top -l 1 -pid N -stats pid,mem` output into bytes ("23M", "15G", "512K", "3092K+").
    public static func topMemory(_ output: String, pid: Int32) -> UInt64? {
        for line in output.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 2, Int32(cols[0]) == pid else { continue }
            return memorySize(cols[1])
        }
        return nil
    }

    static func memorySize(_ text: some StringProtocol) -> UInt64? {
        var s = Substring(text)
        while let last = s.last, last == "+" || last == "-" { s = s.dropLast() }
        guard let unit = s.last else { return nil }
        let multipliers: [Character: Double] = ["B": 1, "K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024, "T": 1024 * 1024 * 1024 * 1024]
        if let m = multipliers[unit], let v = Double(s.dropLast()) { return UInt64(v * m) }
        return Double(s).map { UInt64($0) }
    }
}

public enum Shell {
    /// Runs an executable and returns its stdout. Stderr is discarded.
    public static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ProcessList {
    public static func snapshot() throws -> [PSRow] {
        PSParser.parse(try Shell.run("/bin/ps", PSParser.arguments))
    }

    /// Physical footprint as reported by `top`, or nil if it can't be read.
    public static func footprint(pid: Int32) -> UInt64? {
        guard let out = try? Shell.run("/usr/bin/top", ["-l", "1", "-pid", String(pid), "-stats", "pid,mem"]) else { return nil }
        return PSParser.topMemory(out, pid: pid)
    }
}

import Foundation
import SQLite3

/// One service's aggregate for one poll.
public struct ServiceSampleRow: Equatable, Sendable {
    public var service: String
    public var instances: Int
    public var cpuTotal: Double
    public var cpuMax: Double
    public var rssTotal: UInt64
    public var rssMax: UInt64
    public var topPID: Int32

    public init(service: String, instances: Int, cpuTotal: Double, cpuMax: Double,
                rssTotal: UInt64, rssMax: UInt64, topPID: Int32) {
        self.service = service
        self.instances = instances
        self.cpuTotal = cpuTotal
        self.cpuMax = cpuMax
        self.rssTotal = rssTotal
        self.rssMax = rssMax
        self.topPID = topPID
    }

    /// Aggregates a service's instances; nil until at least one has a CPU rate.
    public static func aggregate(service: String, _ samples: [ProcSample]) -> ServiceSampleRow? {
        let rated = samples.filter { $0.cpuPercent != nil }
        guard let top = rated.max(by: { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }) else { return nil }
        let cpus = rated.compactMap(\.cpuPercent)
        return ServiceSampleRow(service: service, instances: samples.count,
                                cpuTotal: cpus.reduce(0, +), cpuMax: cpus.max() ?? 0,
                                rssTotal: samples.reduce(0) { $0 + $1.rssBytes },
                                rssMax: samples.map(\.rssBytes).max() ?? 0, topPID: top.pid)
    }
}

public struct MetricPoint: Equatable, Sendable, Identifiable {
    public var date: Date
    public var cpu: Double
    public var cpuPeak: Double
    public var rss: Double
    public var rssPeak: Double
    public var id: Date { date }

    public init(date: Date, cpu: Double, cpuPeak: Double, rss: Double, rssPeak: Double) {
        self.date = date
        self.cpu = cpu
        self.cpuPeak = cpuPeak
        self.rss = rss
        self.rssPeak = rssPeak
    }
}

public enum EventKind: String, CaseIterable, Sendable {
    case flagged, notified, snoozed, ignored, cleared, respawned
    case restartRequested = "restart_requested"
    case restarted
    case restartCancelled = "restart_cancelled"
    case restartFailed = "restart_failed"
}

public struct MetricEvent: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var date: Date
    public var service: String
    public var pid: Int32?
    public var kind: String
    public var detail: String

    public var pidSortKey: Int64 { Int64(pid ?? -1) }
}

public enum MetricsError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case .sqlite(let m): return "SQLite: \(m)" }
    }
}

/// SQLite-backed history: raw samples (48 h), 5-minute rollups (30 d), events (180 d).
public final class MetricsStore {
    public static let rawRetention: TimeInterval = 48 * 3600
    public static let rollupRetention: TimeInterval = 30 * 86_400
    public static let eventRetention: TimeInterval = 180 * 86_400
    public static let bucketSeconds: TimeInterval = 300
    /// Ranges up to this length are drawn from raw samples, longer ones from rollups.
    public static let rawRangeLimit: TimeInterval = 24 * 3600

    private var db: OpaquePointer?
    private var rolledUpTo: Double?

    /// Pass ":memory:" for an in-memory database.
    public init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw MetricsError.sqlite(message)
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS samples(
                ts REAL NOT NULL, service TEXT NOT NULL, instances INTEGER NOT NULL,
                cpu_total REAL NOT NULL, cpu_max REAL NOT NULL,
                rss_total INTEGER NOT NULL, rss_max INTEGER NOT NULL, top_pid INTEGER);
            CREATE INDEX IF NOT EXISTS samples_service_ts ON samples(service, ts);
            CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
            CREATE TABLE IF NOT EXISTS rollups(
                bucket_ts INTEGER NOT NULL, service TEXT NOT NULL,
                cpu_avg REAL NOT NULL, cpu_max REAL NOT NULL,
                rss_avg REAL NOT NULL, rss_max INTEGER NOT NULL,
                PRIMARY KEY(service, bucket_ts));
            CREATE TABLE IF NOT EXISTS events(
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, service TEXT NOT NULL,
                pid INTEGER, kind TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Writing

    /// Writes one poll's rows in a single transaction and rolls up any completed buckets.
    public func record(_ rows: [ServiceSampleRow], at date: Date) throws {
        guard !rows.isEmpty else { return }
        let ts = date.timeIntervalSince1970
        try exec("BEGIN")
        do {
            for r in rows {
                try run("INSERT INTO samples(ts, service, instances, cpu_total, cpu_max, rss_total, rss_max, top_pid) VALUES (?,?,?,?,?,?,?,?)",
                        [.real(ts), .text(r.service), .int(Int64(r.instances)), .real(r.cpuTotal), .real(r.cpuMax),
                         .int(Int64(r.rssTotal)), .int(Int64(r.rssMax)), .int(Int64(r.topPID))])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        try rollup(now: date)
    }

    public func log(_ kind: EventKind, service: String, pid: Int32?, detail: String = "", at date: Date = Date()) throws {
        try run("INSERT INTO events(ts, service, pid, kind, detail) VALUES (?,?,?,?,?)",
                [.real(date.timeIntervalSince1970), .text(service), pid.map { .int(Int64($0)) } ?? .null,
                 .text(kind.rawValue), .text(detail)])
    }

    /// Aggregates every completed 5-minute bucket not yet rolled up.
    public func rollup(now: Date) throws {
        let b = Self.bucketSeconds
        let end = floor(now.timeIntervalSince1970 / b) * b
        if rolledUpTo == nil {
            if let last = try scalarDouble("SELECT MAX(bucket_ts) FROM rollups") {
                rolledUpTo = last + b
            } else if let first = try scalarDouble("SELECT MIN(ts) FROM samples") {
                rolledUpTo = floor(first / b) * b
            }
        }
        guard let start = rolledUpTo, start < end else { return }
        try run("""
            INSERT OR REPLACE INTO rollups(bucket_ts, service, cpu_avg, cpu_max, rss_avg, rss_max)
            SELECT CAST(ts / \(Int(b)) AS INTEGER) * \(Int(b)), service,
                   AVG(cpu_total), MAX(cpu_total), AVG(rss_total), MAX(rss_total)
            FROM samples WHERE ts >= ? AND ts < ? GROUP BY 1, 2
            """, [.real(start), .real(end)])
        rolledUpTo = end
    }

    /// Rolls up, then drops data past retention.
    public func prune(now: Date) throws {
        try rollup(now: now)
        let t = now.timeIntervalSince1970
        try run("DELETE FROM samples WHERE ts < ?", [.real(t - Self.rawRetention)])
        try run("DELETE FROM rollups WHERE bucket_ts < ?", [.real(t - Self.rollupRetention)])
        try run("DELETE FROM events WHERE ts < ?", [.real(t - Self.eventRetention)])
    }

    // MARK: Reading

    /// CPU and RSS history. Raw samples for ranges ≤ 24 h; rollups (merged to ≤ ~2000 points) beyond.
    public func series(service: String, from: Date, to: Date) throws -> [MetricPoint] {
        let span = to.timeIntervalSince(from)
        var points: [MetricPoint] = []
        if span <= Self.rawRangeLimit {
            try run("SELECT ts, cpu_total, rss_total FROM samples WHERE service = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                    [.text(service), .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { st in
                let cpu = sqlite3_column_double(st, 1), rss = sqlite3_column_double(st, 2)
                points.append(MetricPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)),
                                          cpu: cpu, cpuPeak: cpu, rss: rss, rssPeak: rss))
            }
        } else {
            let b = Self.bucketSeconds
            let bucket = Int(max(b, ceil(span / 2000 / b) * b))
            try run("""
                SELECT CAST(bucket_ts / \(bucket) AS INTEGER) * \(bucket), AVG(cpu_avg), MAX(cpu_max), AVG(rss_avg), MAX(rss_max)
                FROM rollups WHERE service = ? AND bucket_ts >= ? AND bucket_ts <= ? GROUP BY 1 ORDER BY 1
                """, [.text(service), .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { st in
                points.append(MetricPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)),
                                          cpu: sqlite3_column_double(st, 1), cpuPeak: sqlite3_column_double(st, 2),
                                          rss: sqlite3_column_double(st, 3), rssPeak: sqlite3_column_double(st, 4)))
            }
        }
        return points
    }

    /// Average CPU per `bucket` seconds for every service since `since`, for sparklines.
    public func sparklines(since: Date, bucket: Int = 900) throws -> [String: [MetricPoint]] {
        var result: [String: [MetricPoint]] = [:]
        try run("""
            SELECT service, CAST(ts / \(bucket) AS INTEGER) * \(bucket), AVG(cpu_total), MAX(cpu_total), AVG(rss_total), MAX(rss_total)
            FROM samples WHERE ts >= ? GROUP BY 1, 2 ORDER BY 1, 2
            """, [.real(since.timeIntervalSince1970)]) { st in
            let service = String(cString: sqlite3_column_text(st, 0))
            result[service, default: []].append(
                MetricPoint(date: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                            cpu: sqlite3_column_double(st, 2), cpuPeak: sqlite3_column_double(st, 3),
                            rss: sqlite3_column_double(st, 4), rssPeak: sqlite3_column_double(st, 5)))
        }
        return result
    }

    /// Timestamp of the oldest raw sample at or after `since`, if any.
    public func oldestSample(since: Date) throws -> Date? {
        var value: Date?
        try run("SELECT MIN(ts) FROM samples WHERE ts >= ?", [.real(since.timeIntervalSince1970)]) { st in
            if sqlite3_column_type(st, 0) != SQLITE_NULL { value = Date(timeIntervalSince1970: sqlite3_column_double(st, 0)) }
        }
        return value
    }

    public func events(service: String? = nil, since: Date, limit: Int = 5000) throws -> [MetricEvent] {
        var out: [MetricEvent] = []
        var sql = "SELECT id, ts, service, pid, kind, detail FROM events WHERE ts >= ?"
        var args: [SQLValue] = [.real(since.timeIntervalSince1970)]
        if let service {
            sql += " AND service = ?"
            args.append(.text(service))
        }
        sql += " ORDER BY ts DESC, id DESC LIMIT \(limit)"
        try run(sql, args) { st in
            out.append(MetricEvent(
                id: sqlite3_column_int64(st, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                service: String(cString: sqlite3_column_text(st, 2)),
                pid: sqlite3_column_type(st, 3) == SQLITE_NULL ? nil : Int32(sqlite3_column_int64(st, 3)),
                kind: String(cString: sqlite3_column_text(st, 4)),
                detail: String(cString: sqlite3_column_text(st, 5))))
        }
        return out
    }

    /// Number of events of `kind` per service since `since`.
    public func eventCounts(_ kind: EventKind, since: Date) throws -> [String: Int] {
        var out: [String: Int] = [:]
        try run("SELECT service, COUNT(*) FROM events WHERE kind = ? AND ts >= ? GROUP BY service",
                [.text(kind.rawValue), .real(since.timeIntervalSince1970)]) { st in
            out[String(cString: sqlite3_column_text(st, 0))] = Int(sqlite3_column_int64(st, 1))
        }
        return out
    }

    public func count(table: String) throws -> Int {
        precondition(["samples", "rollups", "events"].contains(table))
        return Int(try scalarDouble("SELECT COUNT(*) FROM \(table)") ?? 0)
    }

    // MARK: SQLite plumbing

    enum SQLValue {
        case int(Int64), real(Double), text(String), null
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw MetricsError.sqlite(message)
        }
    }

    private func run(_ sql: String, _ args: [SQLValue] = [], row: ((OpaquePointer) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MetricsError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                row?(stmt)
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw MetricsError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func scalarDouble(_ sql: String) throws -> Double? {
        var value: Double?
        try run(sql) { st in
            if sqlite3_column_type(st, 0) != SQLITE_NULL { value = sqlite3_column_double(st, 0) }
        }
        return value
    }
}

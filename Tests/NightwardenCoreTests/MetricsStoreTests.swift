import Foundation
import Testing
@testable import NightwardenCore

@Suite struct MetricsStoreTests {
    // Aligned to a 5-minute bucket.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 300))

    func row(_ service: String, cpu: Double, rss: UInt64) -> ServiceSampleRow {
        ServiceSampleRow(service: service, instances: 1, cpuTotal: cpu, cpuMax: cpu, rssTotal: rss, rssMax: rss, topPID: 1)
    }

    @Test func insertAndRangeQuery() throws {
        let store = try MetricsStore(path: ":memory:")
        for i in 0..<10 {
            try store.record([row("a", cpu: Double(i), rss: 100), row("b", cpu: 1, rss: 1)], at: t0 + Double(i * 30))
        }
        #expect(try store.count(table: "samples") == 20)
        let points = try store.series(service: "a", from: t0 + 60, to: t0 + 150)
        #expect(points.map(\.cpu) == [2, 3, 4, 5])
    }

    @Test func rollupBuckets() throws {
        let store = try MetricsStore(path: ":memory:")
        // 20 samples, 30 s apart: two full buckets (0-299, 300-599).
        for i in 0..<20 {
            try store.record([row("a", cpu: i < 10 ? 10 : 30, rss: UInt64(i < 10 ? 100 : 300))], at: t0 + Double(i * 30))
        }
        #expect(try store.count(table: "rollups") == 1)  // second bucket still open
        try store.rollup(now: t0 + 600)
        #expect(try store.count(table: "rollups") == 2)

        let points = try store.series(service: "a", from: t0 - 86400 * 2, to: t0 + 600)
        #expect(points.count == 2)
        #expect(points[0].date == t0)
        #expect(points[0].cpu == 10)
        #expect(points[1].cpu == 30)
        #expect(points[1].rssPeak == 300)
    }

    @Test func rollupSurvivesReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let store = try MetricsStore(path: path)
            try store.record([row("a", cpu: 1, rss: 1)], at: t0)
            try store.record([row("a", cpu: 1, rss: 1)], at: t0 + 300)
        }
        let store = try MetricsStore(path: path)
        try store.record([row("a", cpu: 1, rss: 1)], at: t0 + 600)
        #expect(try store.count(table: "rollups") == 2)
    }

    @Test func pruning() throws {
        let store = try MetricsStore(path: ":memory:")
        let now = t0 + 200 * 86400
        try store.record([row("a", cpu: 1, rss: 1)], at: now - 31 * 86400)   // rollup expires too
        try store.record([row("a", cpu: 2, rss: 1)], at: now - 3 * 86400)    // raw expires, rollup kept
        try store.record([row("a", cpu: 3, rss: 1)], at: now - 3600)         // kept
        try store.log(.restarted, service: "a", pid: 1, at: now - 181 * 86400)
        try store.log(.restarted, service: "a", pid: 2, at: now - 10 * 86400)
        try store.prune(now: now)

        #expect(try store.count(table: "samples") == 1)
        #expect(try store.count(table: "rollups") == 2)
        #expect(try store.count(table: "events") == 1)
        #expect(try store.eventCounts(.restarted, since: now - 30 * 86400) == ["a": 1])
    }

    @Test func eventsAndSparklines() throws {
        let store = try MetricsStore(path: ":memory:")
        try store.log(.flagged, service: "yes", pid: 42, detail: "CPU", at: t0)
        try store.log(.notified, service: "yes", pid: 42, at: t0 + 1)
        try store.log(.respawned, service: "other", pid: nil, at: t0 + 2)
        let yes = try store.events(service: "yes", since: t0 - 1)
        #expect(yes.map(\.kind) == ["notified", "flagged"])
        #expect(try store.events(since: t0 - 1).first?.pid == nil)

        for i in 0..<4 { try store.record([row("a", cpu: Double(i), rss: 1)], at: t0 + Double(i * 300)) }
        let spark = try store.sparklines(since: t0 - 1, bucket: 900)
        #expect(spark["a"]?.map(\.cpu) == [1, 3])
        #expect(try store.oldestSample(since: t0 + 1) == t0 + 300)
    }

    @Test func aggregateInstances() {
        let samples = [
            ProcSample(pid: 1, uid: 0, service: "trustd", command: "t", rssBytes: 10, cpuPercent: 5, cpuSeconds: 0, uptime: 0),
            ProcSample(pid: 2, uid: 501, service: "trustd", command: "t", rssBytes: 30, cpuPercent: 20, cpuSeconds: 0, uptime: 0),
            ProcSample(pid: 3, uid: 501, service: "trustd", command: "t", rssBytes: 5, cpuPercent: nil, cpuSeconds: 0, uptime: 0),
        ]
        let row = ServiceSampleRow.aggregate(service: "trustd", samples)
        #expect(row == ServiceSampleRow(service: "trustd", instances: 3, cpuTotal: 25, cpuMax: 20, rssTotal: 45, rssMax: 30, topPID: 2))
        #expect(ServiceSampleRow.aggregate(service: "x", [samples[2]]) == nil)
    }
}

import Foundation
import Testing
@testable import NightwardenCore

@Suite struct DetectorTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let rules = ["fseventsd": Rule(cpuPercent: 80, cpuMinutes: 10, memoryLimitBytes: 2 << 30, restartable: true)]

    func sample(pid: Int32 = 100, cpu: Double?, rss: UInt64 = 10 << 20, command: String = "/x/fseventsd") -> ProcSample {
        ProcSample(pid: pid, uid: 0, service: "fseventsd", command: command, rssBytes: rss,
                   cpuPercent: cpu, cpuSeconds: 1000, uptime: 5000)
    }

    /// Feeds `cpus` at 1-minute steps starting at `start` minutes; returns all events.
    func feed(_ d: Detector, _ cpus: [Double?], start: Int = 0, paused: Bool = false) -> [DetectorEvent] {
        cpus.enumerated().flatMap { i, cpu in
            d.update([sample(cpu: cpu)], rules: rules, now: t0 + Double((start + i) * 60), alertsPaused: paused)
        }
    }

    @Test func flagsAfterContinuousHighCPU() {
        let d = Detector()
        #expect(feed(d, [nil, 95, 95, 95, 95, 95, 95, 95, 95, 95]).isEmpty)  // 0...9 min: high since minute 1
        #expect(d.health(pid: 100) == .elevated)
        #expect(d.states[100]?.highSince == t0 + 60)
        let events = feed(d, [95, 95], start: 10)  // minute 11 = 10 min since highSince
        #expect(events.count == 2)
        guard case .flagged(let f) = events[0], case .notify = events[1] else {
            Issue.record("expected flagged + notify, got \(events)")
            return
        }
        #expect(f.cpuStuck && !f.memoryStuck)
        #expect(f.stuckFor(at: t0 + 11 * 60) == 600)
        #expect(d.health(pid: 100) == .flagged)
    }

    @Test func singleDipDoesNotReset() {
        let d = Detector()
        _ = feed(d, [nil, 95, 95, 10, 95])
        #expect(d.states[100]?.highSince == t0 + 60)
    }

    @Test func twoLowSamplesReset() {
        let d = Detector()
        _ = feed(d, [nil, 95, 95, 10, 10])
        #expect(d.states[100]?.highSince == nil)
        #expect(d.health(pid: 100) == .ok)
        _ = feed(d, [95], start: 5)
        #expect(d.states[100]?.highSince == t0 + 300)
    }

    @Test func clearsWhenRecovered() {
        let d = Detector()
        _ = feed(d, [nil] + Array(repeating: 95, count: 12))
        #expect(d.health(pid: 100) == .flagged)
        let events = feed(d, [5, 5], start: 13)
        #expect(events == [.cleared(service: "fseventsd", pid: 100)])
        #expect(d.flags.isEmpty)
    }

    @Test func memoryFlagNeedsTwoSamples() {
        let d = Detector()
        let big: UInt64 = 3 << 30
        #expect(d.update([sample(cpu: 1, rss: big)], rules: rules, now: t0).isEmpty)
        #expect(d.health(pid: 100) == .elevated)
        let events = d.update([sample(cpu: 1, rss: big)], rules: rules, now: t0 + 30)
        guard case .flagged(let f) = events.first else { Issue.record("not flagged"); return }
        #expect(f.memoryStuck && !f.cpuStuck)
        #expect(events.count == 2)
    }

    @Test func renotifyInterval() {
        let d = Detector()
        d.renotifyInterval = 30 * 60
        let events = feed(d, [nil] + Array(repeating: 95, count: 60))
        let notifies = events.filter { if case .notify = $0 { return true } else { return false } }
        // Flag at minute 11, then 41; minute 71 is beyond the feed.
        #expect(notifies.count == 2)
    }

    @Test func snoozeSuppressesUntilExpiry() {
        let d = Detector()
        d.renotifyInterval = 5 * 60
        _ = feed(d, [nil] + Array(repeating: 95, count: 11))  // flagged at minute 11
        d.snooze(pid: 100, until: t0 + 60 * 60)
        let during = feed(d, Array(repeating: 95, count: 40), start: 12)  // minutes 12...51
        #expect(!during.contains { if case .notify = $0 { return true } else { return false } })
        let after = feed(d, [95], start: 60)
        #expect(after.contains { if case .notify = $0 { return true } else { return false } })
    }

    @Test func ignoreAndPauseSuppress() {
        let d = Detector()
        d.renotifyInterval = 60
        _ = feed(d, [nil] + Array(repeating: 95, count: 11))
        d.ignore(pid: 100)
        #expect(!feed(d, [95, 95, 95], start: 12).contains { if case .notify = $0 { return true } else { return false } })

        let paused = Detector()
        let events = feed(paused, [nil] + Array(repeating: 95, count: 12), paused: true)
        #expect(events.contains { if case .flagged = $0 { return true } else { return false } })
        #expect(!events.contains { if case .notify = $0 { return true } else { return false } })
    }

    @Test func respawnDetection() {
        let d = Detector()
        _ = d.update([sample(pid: 100, cpu: nil)], rules: rules, now: t0)
        let events = d.update([sample(pid: 200, cpu: nil)], rules: rules, now: t0 + 30)
        #expect(events == [.respawned(service: "fseventsd", oldPID: 100, newPID: 200)])
        #expect(d.states[100] == nil)

        d.expectRestart(service: "fseventsd", until: t0 + 120)
        #expect(d.update([sample(pid: 300, cpu: nil)], rules: rules, now: t0 + 60).isEmpty)
    }

    @Test func pidReuseStartsFresh() {
        let d = Detector()
        _ = feed(d, [nil, 95, 95])
        _ = d.update([sample(cpu: 95, command: "/other/fseventsd")], rules: rules, now: t0 + 180)
        #expect(d.states[100]?.highSince == t0 + 180)
    }
}

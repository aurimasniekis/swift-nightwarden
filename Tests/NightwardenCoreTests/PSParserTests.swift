import Foundation
import Testing
@testable import NightwardenCore

@Suite struct PSParserTests {
    @Test func parsesRealLines() throws {
        let output = """
            1     0  22656 1070:45.72 75-03:08:26 /sbin/launchd
          415    88 288384 10208:45.72 75-03:07:55 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
        87395     0  11584   0:22.63       34:31 /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd
        93411   501 512464 2110:33.22 33-21:38:18 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
        12345   501  80000   1:02.00    01:02:03 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
            0     0      0 1-02:03:04 75-03:09:00 kernel_task
        """
        let rows = PSParser.parse(output)
        #expect(rows.count == 6)

        let launchd = PSRow(pid: 1, uid: 0, rssBytes: 23_199_744, cpuSeconds: 64_245.72,
                            elapsedSeconds: 6_491_306, command: "/sbin/launchd")
        #expect(rows[0] == launchd)
        #expect(rows[1].name == "WindowServer")
        #expect(abs(rows[1].cpuSeconds - 612_525.72) < 0.001)
        #expect(rows[1].uid == 88)
        #expect(rows[2].name == "fseventsd")
        #expect(rows[2].elapsedSeconds == 2071)
        #expect(rows[3].name == "Finder")
        #expect(rows[3].elapsedSeconds == 2_929_098.0)
        #expect(rows[4].name == "Google Chrome Helper (Renderer)")
        #expect(rows[4].elapsedSeconds == 3723)
        #expect(rows[5].name == "kernel_task")
        #expect(rows[5].cpuSeconds == 93_784.0)
    }

    @Test func durationForms() {
        #expect(PSParser.duration("42") == 42)
        #expect(PSParser.duration("34:31") == 2071)
        #expect(PSParser.duration("01:02:03") == 3723)
        #expect(PSParser.duration("2-00:00:01") == 172_801)
        #expect(PSParser.duration("1687:10.26").map { abs($0 - 101_230.26) < 0.001 } == true)
        #expect(PSParser.duration("") == nil)
        #expect(PSParser.duration("1:2:3:4") == nil)
        #expect(PSParser.duration("ab:cd") == nil)
    }

    @Test func rejectsMalformed() {
        #expect(PSParser.parseLine("  1 0 100 0:01.00") == nil)
        #expect(PSParser.parseLine("x 0 100 0:01.00 00:10 /bin/foo") == nil)
        #expect(PSParser.parseLine("1 0 100 0:01.00 00:10 /bin/foo  ")?.command == "/bin/foo")
    }

    @Test func topMemory() {
        #expect(PSParser.topMemory("PID MEM\n1   23M\n", pid: 1) == 23 * 1024 * 1024)
        #expect(PSParser.topMemory("PID    MEM\n87395  15G+\n", pid: 87395) == 15 * 1024 * 1024 * 1024)
        #expect(PSParser.topMemory("PID MEM\n7  512K-\n", pid: 7) == 512 * 1024)
        #expect(PSParser.topMemory("PID MEM\n7  512K\n", pid: 8) == nil)
    }
}

@Suite struct SamplerTests {
    func row(_ pid: Int32, cpu: Double, command: String = "/usr/libexec/trustd") -> PSRow {
        PSRow(pid: pid, uid: 0, rssBytes: 1024, cpuSeconds: cpu, elapsedSeconds: 100, command: command)
    }

    @Test func cpuRate() {
        let s = Sampler()
        let t0 = Date(timeIntervalSince1970: 1000)
        let first = s.ingest([row(10, cpu: 100), row(11, cpu: 5), row(12, cpu: 1, command: "/bin/other")],
                             services: ["trustd"], at: t0)
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0.cpuPercent == nil })

        let second = s.ingest([row(10, cpu: 115), row(11, cpu: 5.3)], services: ["trustd"], at: t0.addingTimeInterval(30))
        #expect(second.first { $0.pid == 10 }?.cpuPercent == 50)
        #expect(abs((second.first { $0.pid == 11 }?.cpuPercent ?? 0) - 1) < 0.0001)
    }

    @Test func pidReuseResetsRate() {
        let s = Sampler()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = s.ingest([row(10, cpu: 100, command: "/usr/libexec/trustd")], services: ["trustd", "cloudd"], at: t0)
        let next = s.ingest([row(10, cpu: 1, command: "/usr/libexec/cloudd")], services: ["trustd", "cloudd"], at: t0 + 30)
        #expect(next.first?.cpuPercent == nil)
        #expect(next.first?.service == "cloudd")
    }

    @Test func kernelTaskEstimate() {
        let s = Sampler()
        let t0 = Date(timeIntervalSince1970: 1000)
        let services: Set<String> = ["kernel_task", "trustd"]
        let first = s.ingest([row(10, cpu: 100), row(11, cpu: 50, command: "/bin/other")], services: services, at: t0, hostBusy: 5000)
        #expect(first.count == 2)
        #expect(first.last?.service == "kernel_task" && first.last?.cpuPercent == nil && first.last?.estimated == true)

        // 10 s wall, host busy +20 s; visible: trustd +5, other +3, a process born mid-interval with 2 s → kernel 10 s = 100%.
        let born = PSRow(pid: 99, uid: 0, rssBytes: 0, cpuSeconds: 2, elapsedSeconds: 4, command: "/bin/new")
        let second = s.ingest([row(10, cpu: 105), row(11, cpu: 53, command: "/bin/other"), born],
                              services: services, at: t0 + 10, hostBusy: 5020)
        let kernel = second.first { $0.service == "kernel_task" }
        #expect(kernel.map { abs(($0.cpuPercent ?? 0) - 100) < 0.0001 } == true)
        #expect(kernel?.pid == 0)
        #expect(second.first { $0.pid == 10 }?.cpuPercent == 50)

        // A real PID 0 row (running as root) wins over the estimate.
        let real = PSRow(pid: 0, uid: 0, rssBytes: 0, cpuSeconds: 10, elapsedSeconds: 1e6, command: "kernel_task")
        let third = s.ingest([real], services: services, at: t0 + 20, hostBusy: 5030)
        #expect(third.count == 1 && third[0].estimated == false)
    }

    @Test func cpuTimeGoingBackwardsIsUnknown() {
        let s = Sampler()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = s.ingest([row(10, cpu: 100)], services: ["trustd"], at: t0)
        #expect(s.ingest([row(10, cpu: 50)], services: ["trustd"], at: t0 + 30).first?.cpuPercent == nil)
    }
}

@Suite struct FormatTests {
    @Test func durations() {
        #expect(Format.duration(45) == "45s")
        #expect(Format.duration(12 * 60 + 5) == "12m")
        #expect(Format.duration(3 * 3600) == "3h")
        #expect(Format.duration(3 * 3600 + 5 * 60) == "3h 5m")
        #expect(Format.duration(75 * 86400 + 2 * 3600 + 59) == "75d 2h")
        #expect(Format.duration(-5) == "0s")
    }

    @Test func bytes() {
        #expect(Format.bytes(512 * 1024) == "512 KB")
        #expect(Format.bytes(11 * 1024 * 1024) == "11 MB")
        #expect(Format.bytes(2048 * 1024 * 1024) == "2 GB")
        #expect(Format.bytes(UInt64(15.2 * 1024 * 1024 * 1024)) == "15.2 GB")
    }

    @Test func lifetime() {
        let uptime = 75.0 * 86400
        #expect(Format.lifetimeCPU(cpuSeconds: 246 * 3600 + 100, uptime: uptime) == "246h CPU lifetime (14% avg)")
        #expect(Format.lifetimeCPU(cpuSeconds: 90, uptime: 900) == "1m CPU lifetime (10% avg)")
    }

    @Test func stuckBody() {
        let now = Date(timeIntervalSince1970: 10_000)
        let sample = ProcSample(pid: 1, uid: 0, service: "fseventsd", command: "/x/fseventsd", rssBytes: 1,
                                cpuPercent: 98, cpuSeconds: 246 * 3600, uptime: 75 * 86400 + 2 * 3600)
        let flag = Flag(sample: sample, cpuStuck: true, memoryStuck: false,
                        highSince: now - 12 * 60, flaggedSince: now - 120)
        #expect(Format.stuckBody(flag, memoryBytes: UInt64(15.2 * 1024 * 1024 * 1024), limitBytes: nil, now: now)
                == "98% CPU for 12m · 15.2 GB memory · up 75d 2h · 246h CPU lifetime (14% avg)")

        let memFlag = Flag(sample: sample, cpuStuck: false, memoryStuck: true, highSince: nil, flaggedSince: now - 60)
        #expect(Format.stuckBody(memFlag, memoryBytes: 3 << 30, limitBytes: 2 << 30, now: now)
                == "3 GB memory (limit 2 GB) · 98% CPU · up 75d 2h · 246h CPU lifetime (14% avg)")
    }
}

@Suite struct ConfigTests {
    @Test func roundTripAndDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        var config = store.load()
        #expect(config.services.count == Config.defaultServices.count)
        config.pollSeconds = 10
        config.services = [ServiceConfig(name: "yes", restartable: true, cpuMinutes: 1)]
        try store.save(config)
        let loaded = store.load()
        #expect(loaded.pollSeconds == 10)
        #expect(loaded.services.map(\.name) == ["yes"])
        #expect(loaded.rules["yes"] == Rule(cpuPercent: 80, cpuMinutes: 1, memoryLimitBytes: nil, restartable: true))
    }

    @Test func partialJSONUsesDefaults() throws {
        let json = #"{"pollSeconds": 5, "services": [{"name": "yes", "cpuMinutes": 1, "restartable": true}]}"#
        let config = try ConfigStore.decoder.decode(Config.self, from: Data(json.utf8)).sanitized
        #expect(config.pollSeconds == 10)
        #expect(config.defaultCPUPercent == 80)
        #expect(config.services[0].enabled)
        #expect(config.checkForUpdates)
    }

    @Test func protectedServicesNeverRestart() {
        var config = Config()
        for i in config.services.indices { config.services[i].restartable = true }
        for name in Config.protectedServices {
            #expect(config.rules[name]?.restartable == false)
        }
        #expect(config.rules["fseventsd"]?.restartable == true)
        #expect(config.rules["kernel_task"]?.memoryLimitBytes == nil)
        #expect(config.rules["mds_stores"] == Rule(cpuPercent: 80, cpuMinutes: 30, memoryLimitBytes: 4 << 30, restartable: true))
    }
}

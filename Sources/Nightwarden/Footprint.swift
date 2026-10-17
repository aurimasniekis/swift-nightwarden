import NightwardenCore

enum Footprint {
    /// Physical footprint via `top` (takes about a second), off the main thread.
    static func measure(pid: Int32) async -> UInt64? {
        await Task.detached(priority: .utility) { ProcessList.footprint(pid: pid) }.value
    }
}

extension ProcessList {
    static func snapshotAsync() async -> [PSRow]? {
        await Task.detached(priority: .utility) { try? ProcessList.snapshot() }.value
    }
}

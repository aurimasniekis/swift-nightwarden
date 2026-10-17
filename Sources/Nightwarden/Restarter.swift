import AppKit
import NightwardenCore

enum RestartOutcome {
    case respawned(PSRow)
    case notRespawned
    case cancelled
    case failed(String)
}

/// Kills a watched process (own uid directly, otherwise via the admin dialog) and waits for launchd to respawn it.
@MainActor
final class Restarter {
    static let respawnTimeout = 15

    func restart(_ target: ProcSample) async -> RestartOutcome {
        guard !Config.protectedServices.contains(target.service) else {
            return .failed("\(target.service) is protected and is never restarted.")
        }
        guard let before = await ProcessList.snapshotAsync() else { return .failed("Couldn't list processes.") }
        // Re-verify: the PID must still be the same executable.
        guard let row = before.first(where: { $0.pid == target.pid }), row.command == target.command else {
            return .failed("PID \(target.pid) is no longer \(target.service).")
        }
        let existing = Set(before.filter { $0.command == target.command }.map(\.pid))

        if row.uid == getuid() {
            if let error = await Self.killOwn(pid: target.pid) { return .failed(error) }
        } else {
            bringToFront()
            switch await Self.adminKill(pid: target.pid, service: target.service) {
            case .success: break
            case .cancelled: return .cancelled
            case .failure(let message): return .failed(message)
            }
        }

        for _ in 0..<Self.respawnTimeout {
            try? await Task.sleep(for: .seconds(1))
            if let rows = await ProcessList.snapshotAsync(),
               let fresh = rows.first(where: { $0.command == target.command && !existing.contains($0.pid) }) {
                return .respawned(fresh)
            }
        }
        return .notRespawned
    }

    /// SIGTERM, then SIGKILL if still alive after 3 s. Returns an error message on failure.
    private static func killOwn(pid: Int32) async -> String? {
        await Task.detached {
            guard kill(pid, SIGTERM) == 0 else { return "kill failed: \(String(cString: strerror(errno)))" }
            for _ in 0..<30 {
                usleep(100_000)
                if kill(pid, 0) != 0 { return nil }
            }
            _ = kill(pid, SIGKILL)
            return nil
        }.value
    }

    private enum AdminResult {
        case success, cancelled, failure(String)
    }

    nonisolated static let authenticationTimeout: TimeInterval = 180

    /// Runs the kill as root through the native admin authentication dialog.
    /// Only the integer PID is interpolated into the shell command; the service name only reaches the
    /// prompt text, reduced to safe characters. It runs in an `osascript` child process rather than
    /// in-process `NSAppleScript` (which must block the main thread), so the app stays responsive and a
    /// dialog nobody answers times out instead of hanging the app.
    nonisolated private static func adminKill(pid: Int32, service: String) async -> AdminResult {
        let p = String(pid)
        let shell = "/bin/kill -TERM \(p) || exit 1; sleep 3; if /bin/kill -0 \(p) 2>/dev/null; then /bin/kill -KILL \(p); fi"
        let name = String(service.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "._- ".unicodeScalars.contains($0) })
        let prompt = "Nightwarden wants to restart \(name) (PID \(p))."
        let source = "do shell script \"\(shell)\" with prompt \"\(prompt)\" with administrator privileges"

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { process in
                let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(returning: .failure("No answer to the administrator prompt within \(Int(authenticationTimeout / 60)) minutes."))
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: .success)
                } else if message.contains("(-128)") {
                    continuation.resume(returning: .cancelled)
                } else {
                    continuation.resume(returning: .failure(message.isEmpty ? "osascript exited with \(process.terminationStatus)" : message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure("Couldn't run osascript: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + authenticationTimeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Brings this menu-bar app to the front. The cooperative `NSApp.activate()` (macOS 14+) is ignored
/// while another app is frontmost, which left alerts and the admin prompt hidden behind other windows.
@MainActor
func bringToFront() {
    NSApp.activate(ignoringOtherApps: true)
}

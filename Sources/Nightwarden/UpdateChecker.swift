import Foundation
import NightwardenCore

/// Asks GitHub for the latest published release. This is the app's only network request.
@MainActor
final class UpdateChecker {
    enum Result {
        case available(GitHubRelease)
        /// `latest` is nil when no release has been published yet.
        case upToDate(latest: AppVersion?)
        case failed(String)
    }

    static let interval: TimeInterval = 24 * 3600
    private static let lastCheckKey = "lastUpdateCheck"
    private static let notifiedKey = "notifiedUpdateTag"

    private let defaults = UserDefaults.standard

    var lastCheck: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    var isDue: Bool { lastCheck.map { Date().timeIntervalSince($0) >= Self.interval } ?? true }

    func check() async -> Result {
        var request = URLRequest(url: AppInfo.latestReleaseAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            defaults.set(Date(), forKey: Self.lastCheckKey)
            if status == 404 { return .upToDate(latest: nil) }  // no releases yet
            guard status == 200 else { return .failed("GitHub answered with HTTP \(status).") }
            let release = try GitHubRelease.decode(data)
            return release.isNewer(than: AppInfo.appVersion) ? .available(release) : .upToDate(latest: release.version)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// True once per release, so the automatic check notifies about each version only once.
    func shouldNotify(about release: GitHubRelease) -> Bool {
        defaults.string(forKey: Self.notifiedKey) != release.tagName
    }

    func markNotified(_ release: GitHubRelease) {
        defaults.set(release.tagName, forKey: Self.notifiedKey)
    }
}

extension GitHubRelease {
    /// Disk image if attached, else the zip, else the release page.
    var downloadURL: URL {
        assets.first { $0.name.hasSuffix(".dmg") }?.browserDownloadURL ?? zipAsset?.browserDownloadURL ?? htmlURL
    }
}

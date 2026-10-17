import AppKit
import NightwardenCore
import ServiceManagement

/// Bundle metadata and project links.
enum AppInfo {
    static let name = "Nightwarden"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var appVersion: AppVersion { AppVersion(version) ?? AppVersion("0.0.0")! }

    /// "owner/repo" on GitHub, from Info.plist so forks can point update checks at themselves.
    static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "NightwardenRepository") as? String ?? "aurimasniekis/swift-nightwarden"
    }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
    static var releasesURL: URL { repositoryURL.appendingPathComponent("releases") }
    static var newIssueURL: URL { repositoryURL.appendingPathComponent("issues/new") }
    static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }
}

/// "Open at login" through the system login-items list. Steps aside when `make install`'s
/// LaunchAgent already starts the app, so it never launches twice.
enum LoginItem {
    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Bundle.main.bundleIdentifier ?? "lt.niekis.nightwarden").plist")
    }

    static var managedByLaunchAgent: Bool { FileManager.default.fileExists(atPath: launchAgentURL.path) }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

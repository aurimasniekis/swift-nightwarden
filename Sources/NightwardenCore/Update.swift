import Foundation

/// A dotted version such as "1.2.3" or "v1.2.0-beta.1". Missing components count as zero;
/// a pre-release sorts before the release it precedes.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let numbers: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let parts = s.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    private func number(_ i: Int) -> Int { i < numbers.count ? numbers[i] : 0 }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        !(a < b) && !(b < a)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) where a.number(i) != b.number(i) {
            return a.number(i) < b.number(i)
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }
}

/// The parts of GitHub's "latest release" response that the update check uses.
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let name: String?
    public let htmlURL: URL
    public let body: String?
    public let publishedAt: Date?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
        case assets
    }

    public var version: AppVersion? { AppVersion(tagName) }

    /// The zipped app attached by the release workflow, if any.
    public var zipAsset: Asset? { assets.first { $0.name.hasSuffix(".zip") } }

    public func isNewer(than current: AppVersion) -> Bool {
        version.map { $0 > current } ?? false
    }

    public static func decode(_ data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    /// Release notes trimmed for an alert.
    public func notesExcerpt(limit: Int = 600) -> String? {
        guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        guard body.count > limit else { return body }
        return String(body.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

import Foundation
import Testing
@testable import NightwardenCore

@Suite struct UpdateTests {
    func v(_ s: String) -> AppVersion { AppVersion(s)! }

    @Test func parsing() {
        #expect(v("v1.2.3").numbers == [1, 2, 3])
        #expect(v("0.1").description == "0.1")
        #expect(v("1.0.0-beta.2").prerelease == "beta.2")
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("latest") == nil)
    }

    @Test func ordering() {
        #expect(v("0.1.0") < v("0.2.0"))
        #expect(v("0.9.9") < v("0.10.0"))
        #expect(v("1.2") == v("1.2.0"))
        #expect(!(v("1.2.0") < v("1.2")))
        #expect(v("1.0.0-beta.2") < v("1.0.0"))
        #expect(v("1.0.0-beta.2") < v("1.0.0-beta.10"))
        #expect(v("1.0.0") > v("1.0.0-rc.1"))
    }

    @Test func decodesLatestRelease() throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "Nightwarden v0.2.0",
          "html_url": "https://github.com/aurimasniekis/swift-nightwarden/releases/tag/v0.2.0",
          "body": "## What's new\\n- Update checks",
          "published_at": "2026-10-20T10:00:00Z",
          "draft": false,
          "assets": [
            { "name": "Nightwarden-0.2.0.zip.sha256", "browser_download_url": "https://example.com/a.sha256" },
            { "name": "Nightwarden-0.2.0.zip", "browser_download_url": "https://example.com/a.zip" }
          ]
        }
        """
        let release = try GitHubRelease.decode(Data(json.utf8))
        #expect(release.version == v("0.2.0"))
        #expect(release.zipAsset?.browserDownloadURL.absoluteString == "https://example.com/a.zip")
        #expect(release.publishedAt == Date(timeIntervalSince1970: 1_792_490_400))
        #expect(release.isNewer(than: v("0.1.0")))
        #expect(!release.isNewer(than: v("0.2.0")))
        #expect(!release.isNewer(than: v("0.3.0")))
        #expect(release.notesExcerpt(limit: 10) == "## What's…")
    }
}

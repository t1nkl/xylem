//
//  AboutWindowTests.swift
//  XylemTests
//
//  The About window's fixed texts: Xylem is GPL-3.0-only, so the notice
//  names version 3 and never "any later version"; release links point at
//  the tag publish-release.sh creates.
//

import Foundation
import Testing

struct AboutWindowTests {
    @Test func licenseNoticeIsVersionThreeOnly() {
        #expect(AboutInfo.licenseNotice.contains("version 3 of the License"))
        #expect(!AboutInfo.licenseNotice.localizedCaseInsensitiveContains("later version"))
        #expect(AboutInfo.licenseNotice.contains("WITHOUT ANY WARRANTY"))
    }

    @Test func releaseLinkUsesTheVersionTag() {
        #expect(AboutInfo.releaseURL(version: "1.2.11")?.absoluteString == "https://github.com/t1nkl/xylem/releases/tag/v1.2.11")
    }

    @Test func releaseNotesMissingEmptyOrPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("about-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AboutInfo.releaseNotes(in: try bundle(in: root, notes: nil)) == nil)
        #expect(AboutInfo.releaseNotes(in: try bundle(in: root, notes: "")) == nil)
        #expect(AboutInfo.releaseNotes(in: try bundle(in: root, notes: "### Fixed\n- A thing.\n")) == "### Fixed\n- A thing.")
    }

    /// A fresh bundle folder per case: Bundle caches its resource list.
    private func bundle(in root: URL, notes: String?) throws -> Bundle {
        let url = root.appendingPathComponent("\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let notes { try Data(notes.utf8).write(to: url.appendingPathComponent("ReleaseNotes.md")) }
        return try #require(Bundle(url: url))
    }
}

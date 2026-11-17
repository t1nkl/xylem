//
//  ProjectFolderEncodingTests.swift
//  XylemTests
//
//  Claude Code names `~/.claude/projects/<folder>` with the JS rule
//  `cwd.replace(/[^a-zA-Z0-9]/g, "-")`, applied per UTF-16 code unit. A
//  `/`-only encoder silently missed every project whose path had `_`, `.`,
//  a space or non-ASCII letters, so the stats bar and todos found no
//  session for it. Non-ASCII cases use explicit scalars so NFC/NFD
//  normalisation of this source file can't change the expected count.
//

import Testing
import Foundation

struct ProjectFolderEncodingTests {

    @Test func plainPathReplacesOnlySlashes() {
        #expect(ClaudeProjectPathResolver.encode("/Users/x/Code/Xylem") == "-Users-x-Code-Xylem")
    }

    @Test func underscoreBecomesDash() {
        // Verified against a real folder on disk.
        #expect(
            ClaudeProjectPathResolver.encode("/Users/x/Code/Demo/demo_site")
                == "-Users-x-Code-Demo-demo-site"
        )
    }

    @Test func dotBecomesDash() {
        #expect(ClaudeProjectPathResolver.encode("/Users/x/.config/my.app") == "-Users-x--config-my-app")
    }

    @Test func spaceBecomesDash() {
        #expect(ClaudeProjectPathResolver.encode("/Users/x/My Projects") == "-Users-x-My-Projects")
    }

    @Test func existingDashesAndDigitsAreKept() {
        #expect(ClaudeProjectPathResolver.encode("/srv/sample-api2") == "-srv-sample-api2")
    }

    @Test func cyrillicLettersBecomeOneDashEach() {
        // "Проєкт" - six BMP scalars, one UTF-16 unit each.
        let name = "\u{041F}\u{0440}\u{043E}\u{0454}\u{043A}\u{0442}"
        #expect(ClaudeProjectPathResolver.encode("/Users/x/" + name) == "-Users-x-------")
    }

    @Test func astralCharacterBecomesTwoDashes() {
        // An emoji is a surrogate pair in UTF-16, so JS emits two dashes.
        #expect(ClaudeProjectPathResolver.encode("/a/\u{1F600}b") == "-a---b")
    }

    @Test func sessionFileLocatorDelegatesToResolver() {
        let paths = [
            "/Users/x/Code/Demo/demo_site",
            "/Users/x/My Projects/v1.2",
            "/Users/x/\u{041F}\u{0440}\u{043E}"
        ]
        for path in paths {
            #expect(SessionFileLocator.encodedFolderName(for: path) == ClaudeProjectPathResolver.encode(path))
        }
    }

    @Test func latestSessionFileFindsFolderForUnderscorePath() throws {
        let projects = FileManager.default.temporaryDirectory
            .appending(path: "xylem-projects-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: projects) }
        let cwd = "/Users/x/Code/Demo/demo_site"
        let folder = projects.appending(path: "-Users-x-Code-Demo-demo-site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = folder.appending(path: "abc.jsonl")
        try Data("{}\n".utf8).write(to: session)

        let found = SessionFileLocator.latestSessionFile(for: cwd, projectsDirectory: projects)
        #expect(found?.lastPathComponent == "abc.jsonl")
    }
}

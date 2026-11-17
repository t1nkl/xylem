//
//  ProjectPathDiskDecodeTests.swift
//  XylemTests
//
//  A project folder with no transcript has only its encoded name. The
//  dash-for-slash guess showed `~/Code/acme/billing-api` as
//  `.../billing/api` (seen on a real machine); the path is now found by walking
//  the disk with Claude Code's own encoding, so any folder names work.
//

import Testing
import Foundation

struct ProjectPathDiskDecodeTests {

    private final class Tree {
        let root: URL
        init(_ paths: [String]) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "xylem-decode-\(UUID().uuidString)")
            for path in paths {
                try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        /// The encoded folder name Claude Code would make for `relative`
        /// under the root (the root itself stands in for "/").
        func name(_ relative: String) -> String { ClaudeProjectPathResolver.encode("/" + relative) }
        func decode(_ name: String) -> String? {
            ClaudeProjectPathResolver.decodeOnDisk(name, root: root.path)
                .map { String($0.dropFirst(root.path.count)) }
        }
    }

    @Test func dashesInsideNamesAreKept() throws {
        let tree = try Tree(["Code/acme/billing-api", "Code/acme/search-api",
                             "Code/vendor/acme/lib/tools-kit"])
        #expect(tree.decode(tree.name("Code/acme/billing-api")) == "/Code/acme/billing-api")
        #expect(tree.decode(tree.name("Code/vendor/acme/lib/tools-kit"))
                == "/Code/vendor/acme/lib/tools-kit")
    }

    @Test func dotsUnderscoresSpacesAndNonLatinLetters() throws {
        let cyrillic = "\u{041F}\u{0440}\u{043E}\u{0454}\u{043A}\u{0442}"   // "Проєкт"
        let tree = try Tree(["My Projects/demo_site.v2", ".config/my.app", cyrillic + "/app"])
        #expect(tree.decode(tree.name("My Projects/demo_site.v2")) == "/My Projects/demo_site.v2")
        #expect(tree.decode(tree.name(".config/my.app")) == "/.config/my.app")
        #expect(tree.decode(tree.name(cyrillic + "/app")) == "/" + cyrillic + "/app")
    }

    @Test func caseDifferencesStillMatch() throws {
        let tree = try Tree(["Sites/app"])
        #expect(tree.decode("-sites-app") == "/Sites/app")
    }

    @Test func decomposedLettersMatchTheComposedFolder() throws {
        let composed = "\u{0439}"                // "й" as one scalar
        let decomposed = "\u{0438}\u{0306}"      // "и" + combining breve
        let tree = try Tree([composed + "x"])
        // A shell that reported the decomposed form encodes one dash more.
        #expect(tree.decode(ClaudeProjectPathResolver.encode("/" + decomposed + "x")) == "/" + composed + "x")
        #expect(tree.decode(tree.name(composed + "x")) == "/" + composed + "x")
    }

    @Test func aDeadEndBacktracks() throws {
        // `a-b` exists but holds no `c`; the project is `a/b/c`.
        let tree = try Tree(["a-b", "a/b/c"])
        #expect(tree.decode(tree.name("a/b/c")) == "/a/b/c")
    }

    @Test func aDeletedFolderKeepsItsDashes() throws {
        let tree = try Tree(["Code/acme"])
        #expect(tree.decode(tree.name("Code/acme/old-api")) == "/Code/acme/old-api")
        // Nothing of it exists: no answer (the resolver falls back).
        #expect(tree.decode("-nowhere-at-all") == nil)
    }
}

struct ProjectPathDiskDecodeAmbiguityTests {
    /// Two Cyrillic names of the same length encode identically; the folder
    /// touched last wins.
    @Test func sameLengthNonLatinNamesPickTheNewest() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-decode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let older = "\u{0421}\u{0435}\u{0440}\u{0432}\u{0456}\u{0441}"   // "Сервіс"
        let newer = "\u{041F}\u{0440}\u{043E}\u{0454}\u{043A}\u{0442}"   // "Проєкт"
        for name in [older, newer] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400)],
                                              ofItemAtPath: root.appending(path: older).path)
        let decoded = ClaudeProjectPathResolver.decodeOnDisk(ClaudeProjectPathResolver.encode("/" + newer), root: root.path)
        #expect(decoded.map { ($0 as NSString).lastPathComponent } == newer)
    }
}

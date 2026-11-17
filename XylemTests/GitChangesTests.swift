//
//  GitChangesTests.swift
//  XylemTests
//
//  git status / numstat parsing, the unified diff parser, the changes
//  folder tree and the loaders' caches - against real git where it matters.
//  Sample names only.
//

import Testing
import Foundation

struct GitChangesParserTests {

    @Test func porcelainKindsRenamesAndUntracked() {
        let output = " M src/app.ts\0A  src/new.ts\0 D old.ts\0R  lib/b.ts\0lib/a.ts\0?? notes.md\0UU merge.ts\0MM both.ts\0"
        let changes = GitChangesParser.parseStatus(output)
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        #expect(byPath["src/app.ts"]?.kind == .modified)
        #expect(byPath["src/new.ts"]?.kind == .added)
        #expect(byPath["old.ts"]?.kind == .deleted)
        #expect(byPath["lib/b.ts"]?.kind == .renamed)
        #expect(byPath["lib/b.ts"]?.oldPath == "lib/a.ts")
        #expect(byPath["lib/a.ts"] == nil)                 // the old path isn't its own row
        #expect(byPath["notes.md"]?.kind == .untracked)
        #expect(byPath["merge.ts"]?.kind == .conflicted)
        #expect(byPath["both.ts"]?.kind == .modified)
        #expect(changes.map(\.path) == changes.map(\.path).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func pathsWithSpacesAndNonLatinLetters() {
        let name = "docs/My \u{0444}\u{0430}\u{0439}\u{043B}.md"   // a Cyrillic word
        let changes = GitChangesParser.parseStatus(" M \(name)\0")
        #expect(changes.first?.path == name)
        #expect(changes.first?.name == "My \u{0444}\u{0430}\u{0439}\u{043B}.md")
    }

    @Test func numstatCountsBinaryAndRenames() {
        let output = "24\t3\tsrc/app.ts\0-\t-\tlogo.png\05\t1\t\0lib/a.ts\0lib/b.ts\0"
        let counts = GitChangesParser.parseNumstat(output)
        #expect(counts["src/app.ts"]?.0 == 24)
        #expect(counts["src/app.ts"]?.1 == 3)
        #expect(counts["logo.png"]?.0 == nil)
        #expect(counts["lib/b.ts"]?.0 == 5)
        #expect(counts["lib/a.ts"] == nil)
    }
}

struct UnifiedDiffParserTests {

    @Test func hunksNumberBothSides() {
        let text = """
        diff --git a/a.ts b/a.ts
        index 1..2 100644
        --- a/a.ts
        +++ b/a.ts
        @@ -10,4 +10,5 @@ function run()
         keep
        -old line
        +new line
        +another
         tail
        \\ No newline at end of file

        """
        let doc = UnifiedDiffParser.parse(text)
        #expect(doc.lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context, .note])
        #expect(doc.lines[1].oldNumber == 10 && doc.lines[1].newNumber == 10)
        #expect(doc.lines[2].oldNumber == 11 && doc.lines[2].newNumber == nil)
        #expect(doc.lines[3].newNumber == 11 && doc.lines[4].newNumber == 12)
        #expect(doc.lines[5].oldNumber == 12 && doc.lines[5].newNumber == 13)
        #expect(doc.lines[3].text == "new line")
        #expect(!doc.isBinary && !doc.isTruncated)
    }

    @Test func binaryAndHugeDiffs() {
        #expect(UnifiedDiffParser.parse("diff --git a/x b/x\nBinary files a/x and b/x differ\n").isBinary)
        let many = "@@ -1,1 +1,9000 @@\n" + (0..<9000).map { "+line \($0)" }.joined(separator: "\n")
        let doc = UnifiedDiffParser.parse(many)
        #expect(doc.isTruncated)
        #expect(doc.lines.count == UnifiedDiffParser.maxLines)
        let long = UnifiedDiffParser.parse("@@ -1 +1 @@\n+" + String(repeating: "x", count: 5000))
        #expect(long.lines.last?.text.count == UnifiedDiffParser.maxLineLength + 1)
    }

    /// A real git: an untracked file diffs against /dev/null, a tracked
    /// edit against HEAD, through the loader.
    @Test func loaderReadsARealRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-drawer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + args
            p.currentDirectoryURL = root
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        try git("init", "-q")
        try "one\ntwo\nthree\n".write(to: root.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-q", "-m", "init")
        try "one\nTWO\nthree\n".write(to: root.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        try "fresh\nfile\n".write(to: root.appending(path: "new.txt"), atomically: true, encoding: .utf8)

        let snapshot = try #require(await GitChangesLoader.load(in: root.path))
        #expect(snapshot.changes.map(\.path) == ["app.txt", "new.txt"])
        let edited = try #require(snapshot.changes.first)
        #expect(edited.kind == .modified && edited.additions == 1 && edited.deletions == 1)
        let fresh = snapshot.changes[1]
        #expect(fresh.kind == .untracked && fresh.additions == 2)

        let editDiff = await GitChangesLoader.diff(of: edited, root: snapshot.root)
        #expect(editDiff.lines.filter { $0.kind == .removed }.map(\.text) == ["two"])
        #expect(editDiff.lines.filter { $0.kind == .added }.map(\.text) == ["TWO"])
        let newDiff = await GitChangesLoader.diff(of: fresh, root: snapshot.root)
        #expect(newDiff.lines.filter { $0.kind == .added }.map(\.text) == ["fresh", "file"])

        let notRepo = FileManager.default.temporaryDirectory.appending(path: "xylem-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notRepo) }
        #expect(await GitChangesLoader.load(in: notRepo.path) == nil)
    }
}

struct GitParsingEdgeCaseTests {
    @Test func renameInTheSecondColumnAndNestedRepos() {
        // " R": a rename recorded in the work tree (intent-to-add), old path follows.
        let changes = GitChangesParser.parseStatus(" R new.ts\0old.ts\0?? vendor/lib/\0 M app.ts\0")
        #expect(changes.map(\.path) == ["app.ts", "new.ts"])
        #expect(changes.first { $0.path == "new.ts" }?.oldPath == "old.ts")
        #expect(changes.first { $0.path == "new.ts" }?.kind == .renamed)
    }

    @Test func blankContextLinesAndFormFeedsKeepNumbering() {
        // diff.suppressBlankEmpty prints a blank context line as "" and a
        // form feed is part of a line, not a line break.
        let doc = UnifiedDiffParser.parse("@@ -1,4 +1,4 @@\n first\n\n-old\u{0C}tail\n+new\u{0C}tail\n last\n")
        #expect(doc.lines.map(\.kind) == [.hunk, .context, .context, .removed, .added, .context])
        #expect(doc.lines[2].oldNumber == 2 && doc.lines[2].newNumber == 2)
        #expect(doc.lines[5].oldNumber == 4 && doc.lines[5].newNumber == 4)
        #expect(doc.lines[3].text == "old\u{0C}tail")
        #expect(TextLines.split("a\r\nb\u{2028}c\nd") == ["a", "b\u{2028}c", "d"])
    }

    /// A repository without commits: counts from what is staged, and nil
    /// counts that aren't binary don't say "bin".
    @Test func repositoryWithoutCommitsHasCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-nocommit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "one\ntwo\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "a.txt"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
            p.currentDirectoryURL = root; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        let snapshot = try #require(await GitChangesLoader.load(in: root.path))
        let staged = try #require(snapshot.changes.first)
        #expect(staged.kind == .added && staged.additions == 2 && !staged.isBinary)
        let diff = await GitChangesLoader.diff(of: staged, root: snapshot.root)
        #expect(diff.lines.filter { $0.kind == .added }.map(\.text) == ["one", "two"])
    }
}

struct ChangeTreeTests {
    private func change(_ path: String, _ kind: GitFileChange.Kind = .modified) -> GitFileChange {
        GitFileChange(path: path, oldPath: nil, kind: kind)
    }

    private func describe(_ rows: [ChangeTree.Row]) -> [String] {
        rows.map { row in
            switch row {
            case .folder(_, let label, let depth, let count): String(repeating: "  ", count: depth) + label + "/ (\(count))"
            case .file(let c, let depth): String(repeating: "  ", count: depth) + c.name
            }
        }
    }

    @Test func foldersFirstNestedAndCompacted() {
        let rows = ChangeTree.rows([
            change("README.md"),
            change("src/webhooks/deliver.ts"),
            change("src/webhooks/retry.ts", .untracked),
            change("src/app.ts"),
            change("api/v1/http/UserController.php"),
            change("tests/unit/billing_test.py"),
        ], collapsed: [])
        #expect(describe(rows) == [
            "api/v1/http/ (1)",            // single-folder chain folded
            "  UserController.php",
            "src/ (3)",
            "  webhooks/ (2)",
            "    deliver.ts",
            "    retry.ts",
            "  app.ts",
            "tests/unit/ (1)",
            "  billing_test.py",
            "README.md",
        ])
    }

    @Test func collapsedFolderHidesItsChildren() {
        let changes = [change("src/webhooks/deliver.ts"), change("src/app.ts"), change("main.go")]
        let rows = ChangeTree.rows(changes, collapsed: ["src"])
        #expect(describe(rows) == ["src/ (2)", "main.go"])
        let inner = ChangeTree.rows(changes, collapsed: ["src/webhooks"])
        #expect(describe(inner) == ["src/ (2)", "  webhooks/ (1)", "  app.ts", "main.go"])
    }
}

struct LockedCacheTests {
    @Test func retainDropsEntriesNoLongerNeeded() {
        let cache = LockedCache<String, Int>()
        cache.set(1, for: "a"); cache.set(2, for: "b")
        cache.retain(["b"])
        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") == 2)
    }
}

// MARK: - A hung git is stopped

struct GitRunnerTimeoutTests {
    /// A git that never finishes (here an alias that sleeps) is stopped at
    /// the limit and reads as a failed call, not a thread held forever.
    @Test func hungGitIsStoppedAtTheLimit() {
        let started = Date()
        let output = GitRepository.runGitBlocking(["-c", "alias.hang=!sleep 20", "hang"],
                                                  in: NSTemporaryDirectory(), timeout: 1)
        #expect(output == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// git exits at once but leaves a child holding its output (a daemon
    /// started by a hook). Reading a pipe to EOF waited for that child too;
    /// the runner returns as soon as git itself is done.
    @Test func aLingeringChildDoesNotHoldTheCall() {
        let started = Date()
        let output = GitRepository.runGitBlocking(["-c", "alias.bg=!(sleep 8 &); echo hi", "bg"],
                                                  in: NSTemporaryDirectory(), timeout: 20)
        #expect(output?.contains("hi") == true)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func normalGitStillWorks() {
        let output = GitRepository.runGitBlocking(["--version"], in: NSTemporaryDirectory(), timeout: 5)
        #expect(output?.hasPrefix("git version") == true)
    }
}

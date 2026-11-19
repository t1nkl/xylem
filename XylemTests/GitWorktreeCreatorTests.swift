//
//  GitWorktreeCreatorTests.swift
//  XylemTests
//
//  New worktree tabs: layout shared with `claude --worktree`, new vs
//  existing branches, git's own errors, and the local exclude line - all
//  against a real throwaway repository.
//

import Testing
import Foundation

struct GitWorktreeCreatorTests {
    private func shell(_ command: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(command)")
    }

    /// A repository with one commit on `main`, symlinks resolved (git
    /// reports real paths: /private/var, not /var).
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "xylem-wt-\(UUID().uuidString)").resolvingSymlinksInPath()
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try shell("git init -q -b main && echo a > a.txt && git add . && git -c user.email=t@t -c user.name=t commit -qm init", in: repo)
        return repo
    }

    @Test func pureLayout() {
        #expect(GitWorktreeCreator.worktreePath(mainCheckout: "/r", branch: "feature/x") == "/r/.claude/worktrees/feature-x")
        #expect(GitWorktreeCreator.mainCheckout(forCommonDir: "/r/.git") == "/r")
        #expect(GitWorktreeCreator.mainCheckout(forCommonDir: "/srv/bare.git") == nil)
        #expect(GitWorktreeCreator.excludeFile(adding: "/x/", to: "") == "/x/\n")
        #expect(GitWorktreeCreator.excludeFile(adding: "/x/", to: "# c") == "# c\n/x/\n")
        #expect(GitWorktreeCreator.excludeFile(adding: "/x/", to: "a\n/x/\n") == nil)
        #expect(GitWorktreeCreator.gitMessage("Preparing worktree (checking out 'main')\nfatal: 'main' is already used")
                == "fatal: 'main' is already used")
        #expect(GitWorktreeCreator.gitMessage("") == "git worktree add failed.")
    }

    @Test func newBranchFromHEADGoesUnderTheMainCheckout() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let path = try await GitWorktreeCreator().create(branch: "feature/one", from: repo.path)
        #expect(path == repo.path + "/.claude/worktrees/feature-one")
        #expect(FileManager.default.fileExists(atPath: path + "/a.txt"))
        let head = try String(contentsOfFile: path + "/.git", encoding: .utf8)
        #expect(head.hasPrefix("gitdir:"))
        // Ignored locally, so the main checkout stays clean.
        let exclude = try String(contentsOf: repo.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").filter { $0 == GitWorktreeCreator.excludeLine }.count == 1)

        // From inside that worktree, the next one still goes under the main
        // checkout, and the exclude line is not added twice.
        let second = try await GitWorktreeCreator().create(branch: "two", from: path)
        #expect(second == repo.path + "/.claude/worktrees/two")
        let again = try String(contentsOf: repo.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(again.components(separatedBy: "\n").filter { $0 == GitWorktreeCreator.excludeLine }.count == 1)
    }

    /// A post-checkout hook that prints far more than a pipe buffer (an
    /// `npm install`): git sends it to stderr, and reading stdout first
    /// would deadlock - the sheet would spin forever.
    @Test func aChattyHookDoesNotDeadlock() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let hook = repo.appending(path: ".git/hooks/post-checkout")
        try "#!/bin/sh\nhead -c 300000 /dev/zero | tr '\\0' x\necho\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let started = Date()
        let path = try await GitWorktreeCreator().create(branch: "chatty", from: repo.path)
        #expect(FileManager.default.fileExists(atPath: path + "/a.txt"))
        #expect(Date().timeIntervalSince(started) < 20)
    }

    /// A hook that leaves a process behind holding its output (a watcher,
    /// a dev server): creating the worktree still returns at once.
    @Test func aHookThatLeavesAProcessBehindDoesNotHang() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let hook = repo.appending(path: ".git/hooks/post-checkout")
        try "#!/bin/sh\nsleep 8 &\necho started\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let started = Date()
        let path = try await GitWorktreeCreator().create(branch: "lingering", from: repo.path)
        #expect(FileManager.default.fileExists(atPath: path + "/a.txt"))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func anExistingBranchIsCheckedOutAsIs() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        try shell("git branch existing", in: repo)
        let path = try await GitWorktreeCreator().create(branch: "existing", from: repo.path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func failuresCarryAMessage() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let creator = GitWorktreeCreator()
        await #expect(throws: GitWorktreeCreator.Failure.self) { try await creator.create(branch: "  ", from: repo.path) }
        await #expect(throws: GitWorktreeCreator.Failure.self) { try await creator.create(branch: "bad..name", from: repo.path) }
        // `main` is checked out in the main checkout: git refuses, and says why.
        do {
            _ = try await creator.create(branch: "main", from: repo.path)
            Issue.record("expected a failure")
        } catch let failure as GitWorktreeCreator.Failure {
            #expect(failure.message.hasPrefix("fatal:") && failure.message.contains("main"))
        }
        let outside = repo.deletingLastPathComponent()
        await #expect(throws: GitWorktreeCreator.Failure.self) { try await creator.create(branch: "x", from: outside.path) }
    }
}

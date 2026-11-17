//
//  GitHeadLocatorTests.swift
//  XylemTests
//
//  HEAD resolution for the tab-card branch label: plain repos, nested
//  cwds, linked worktrees (`.git` file) and non-repo directories.
//

import Testing
import Foundation

struct GitHeadLocatorTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xylem-git-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func findsHeadInRepoRootAndSubdirectory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )
        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let expected = git.appendingPathComponent("HEAD").standardizedFileURL.path
        #expect(GitHeadLocator.headPath(forDirectory: root.path) == expected)
        #expect(GitHeadLocator.headPath(forDirectory: nested.path) == expected)
        #expect(GitHeadLocator.modificationDate(ofFile: expected) != nil)
    }

    @Test func followsGitdirFileForWorktrees() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("wt")
        let gitdir = root.appendingPathComponent("main/.git/worktrees/wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try "gitdir: ../main/.git/worktrees/wt\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        let expected = gitdir.appendingPathComponent("HEAD").standardizedFileURL.path
        #expect(GitHeadLocator.headPath(forDirectory: worktree.path) == expected)
    }

    @Test func returnsNilOutsideARepo() throws {
        // Temp dirs live under /var/folders, which is not inside a repo.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GitHeadLocator.headPath(forDirectory: dir.path) == nil)
    }

    // MARK: - Walking up stops at the root

    /// On macOS 15 `URL.deletingLastPathComponent()` of `/` gave `/..`
    /// forever (100% CPU, gigabytes of memory for a home-folder tab). The
    /// walk now uses path strings with an explicit root.
    @Test func parentStopsAtTheRoot() {
        #expect(GitHeadLocator.parent(of: "/") == nil)
        #expect(GitHeadLocator.parent(of: "") == nil)
        #expect(GitHeadLocator.parent(of: "/Users") == "/")
        #expect(GitHeadLocator.parent(of: "/Users/someone") == "/Users")
        #expect(GitHeadLocator.parent(of: "/Users/someone/") == "/Users")
    }

    @Test func foldersOutsideARepositoryEndWithNil() throws {
        // The root itself and a temp folder (not inside any repository).
        #expect(GitHeadLocator.headPath(forDirectory: "/") == nil)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GitHeadLocator.headPath(forDirectory: dir.path) == nil)
    }

    @Test func everyChainOfParentsIsFinite() {
        var path = "/a/b/c/d/e/f"
        var steps = 0
        while let parent = GitHeadLocator.parent(of: path) { path = parent; steps += 1 }
        #expect(path == "/")
        #expect(steps == 6)
    }
}

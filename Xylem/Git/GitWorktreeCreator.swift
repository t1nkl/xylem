//
//  GitWorktreeCreator.swift
//  Xylem
//
//  "New worktree tab": a second Claude in the same repository without the
//  two stepping on each other's files. Xylem creates the worktree itself
//  and opens an ordinary project tab in it, rather than starting
//  `claude --worktree` in the repo root: that way the tab's folder, its
//  branch line, the transcript Claude Code files under the worktree path
//  and `--resume` after a relaunch all line up like any other project.
//
//  Layout follows Claude Code's own `--worktree` (checked on 2.1.325):
//  `<main checkout>/.claude/worktrees/<name>`, so worktrees made either way
//  sit together. One difference: `/.claude/worktrees/` is added to the
//  repository's local `info/exclude` (never to a tracked `.gitignore`).
//  Without it a nested worktree shows up as untracked, and a `git add -A`
//  in the main checkout would stage it as an embedded repository.
//
//  The branch is created from the active tab's HEAD; an existing branch
//  that isn't checked out anywhere is used as is.
//

import Foundation

nonisolated struct GitWorktreeCreator {
    struct Failure: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Where a branch's worktree goes: `/` would nest folders, so it
    /// becomes `-` (Claude Code's names have no slashes).
    static func worktreePath(mainCheckout: String, branch: String) -> String {
        let folder = branch.replacingOccurrences(of: "/", with: "-")
        return (mainCheckout as NSString).appendingPathComponent(".claude/worktrees/\(folder)")
    }

    /// The main checkout for a repository's common git dir (`<root>/.git`).
    /// nil for a bare repository, which has no checkout to put them under.
    static func mainCheckout(forCommonDir commonDir: String) -> String? {
        let url = URL(fileURLWithPath: commonDir).standardizedFileURL
        guard url.lastPathComponent == ".git" else { return nil }
        return url.deletingLastPathComponent().path
    }

    static let excludeLine = "/.claude/worktrees/"

    /// `content` with the exclude line appended unless it is already there.
    static func excludeFile(adding line: String, to content: String) -> String? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) else { return nil }
        let separator = content.isEmpty || content.hasSuffix("\n") ? "" : "\n"
        return content + separator + line + "\n"
    }

    /// Creates the worktree for `branch` from the repository `directory`
    /// is in, and returns its path. The git calls block (a checkout of a
    /// large repository takes seconds), so they run on a GCD thread rather
    /// than holding a Swift concurrency thread - same as GitRepository.
    func create(branch: String, from directory: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.createBlocking(branch: branch, from: directory) })
            }
        }
    }

    private static func createBlocking(branch rawBranch: String, from directory: String) throws -> String {
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw Failure(message: "Enter a branch name.") }
        guard git(["check-ref-format", "--branch", branch], in: directory).ok else {
            throw Failure(message: "\"\(branch)\" is not a valid branch name.")
        }
        let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)
        guard common.ok else { throw Failure(message: "The active tab's folder is not in a git repository.") }
        guard let main = mainCheckout(forCommonDir: common.output) else {
            throw Failure(message: "Bare repositories are not supported.")
        }
        let path = worktreePath(mainCheckout: main, branch: branch)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw Failure(message: "\(abbreviated(path)) already exists.")
        }

        let exists = git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: directory).ok
        let arguments = exists
            ? ["worktree", "add", path, branch]
            : ["worktree", "add", "-b", branch, path, "HEAD"]
        let added = git(arguments, in: directory)
        guard added.ok else { throw Failure(message: gitMessage(added.error)) }
        excludeWorktrees(commonDir: common.output)
        return path
    }

    /// Best effort: a read-only `info/exclude` only costs the nicety.
    private static func excludeWorktrees(commonDir: String) {
        let info = URL(fileURLWithPath: commonDir).appending(path: "info", directoryHint: .isDirectory)
        let file = info.appending(path: "exclude")
        // Something other than a regular file under that name (a FIFO would
        // block both the read and the write): leave it alone.
        if FileManager.default.fileExists(atPath: file.path), !SafeFileRead.isRegularFile(file.path) { return }
        let content = SafeFileRead.string(file) ?? ""
        guard let updated = excludeFile(adding: excludeLine, to: content) else { return }
        try? FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try? updated.write(to: file, atomically: true, encoding: .utf8)
    }

    /// git's reason without its progress chatter ("Preparing worktree
    /// (checking out 'main')" comes before "fatal: 'main' is already used…").
    static func gitMessage(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        let errors = lines.filter { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
        let message = (errors.isEmpty ? lines : errors).joined(separator: "\n")
        return message.isEmpty ? "git worktree add failed." : message
    }

    private static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - git

    private struct Outcome {
        let ok: Bool
        let output: String
        let error: String
    }

    /// Longest a worktree command may run (its hook may install packages).
    static let timeout: TimeInterval = 300

    /// Unlike GitRepository's reader, keeps stderr: git's own message is
    /// the best explanation of why a worktree couldn't be made. Output goes
    /// through `ProcessRunner`'s temp files: `worktree add` runs the
    /// repository's post-checkout hook with its output on stderr, and with
    /// pipes a hook that printed more than a pipe buffer deadlocked the
    /// sheet, and one that left a process behind kept it waiting forever.
    private static func git(_ arguments: [String], in directory: String) -> Outcome {
        guard let result = ProcessRunner.run("/usr/bin/git", arguments, in: directory,
                                             captureErrors: true, timeout: timeout)
        else { return Outcome(ok: false, output: "", error: "git couldn't be started.") }
        if result.timedOut {
            return Outcome(ok: false, output: "", error: "git took longer than \(Int(timeout / 60)) minutes and was stopped.")
        }
        return Outcome(
            ok: result.exited && result.status == 0,
            output: String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            error: String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

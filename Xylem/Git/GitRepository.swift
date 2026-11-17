//
//  GitRepository.swift
//  Xylem
//
//  Async wrapper around the `git` CLI. One entry point (`status(in:)`)
//  gathers everything the sidebar needs in parallel and returns a single
//  GitStatus snapshot. Failures degrade gracefully - a missing section
//  just stays empty.
//
//  Entry points hop to `@concurrent` functions so neither the parsing nor
//  the process launch runs on the caller's (main) actor; the blocking
//  read/wait for each git process happens on a GCD thread, not on the
//  Swift concurrency pool.
//

import Foundation

nonisolated protocol GitRepositoryReading {
    func status(in directory: String) async -> GitStatus?
    func currentBranch(in directory: String) async -> String?
}

nonisolated struct GitRepository: GitRepositoryReading {
    /// Cheap branch-only fetch - used by per-tab UI that wants the current
    /// branch without paying for the full porcelain/worktree/remotes scan.
    func currentBranch(in directory: String) async -> String? {
        await Self.loadCurrentBranch(in: directory)
    }

    func status(in directory: String) async -> GitStatus? {
        await Self.loadStatus(in: directory)
    }

    // MARK: - Off-main entry points

    @concurrent
    private static func loadCurrentBranch(in directory: String) async -> String? {
        guard let raw = await runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: directory) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @concurrent
    private static func loadStatus(in directory: String) async -> GitStatus? {
        guard let branch = await runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty
        else { return nil }

        async let porcelain = runGit(["status", "--porcelain"], in: directory) ?? ""
        async let aheadBehind = runGit(
            ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
            in: directory
        ) ?? "0\t0"
        async let worktrees = loadWorktrees(in: directory)
        async let branches = loadBranches(in: directory, current: branch)
        async let remotes = loadRemotes(in: directory)
        async let commits = loadRecentCommits(in: directory)

        let porcelainResult = await porcelain
        let lines = porcelainResult.split(separator: "\n")
        let modified = lines.filter { !$0.hasPrefix("??") }.count
        let untracked = lines.filter { $0.hasPrefix("??") }.count

        let (ahead, behind) = parseAheadBehind(await aheadBehind)

        return GitStatus(
            branch: branch,
            isDirty: !lines.isEmpty,
            modified: modified,
            untracked: untracked,
            ahead: ahead,
            behind: behind,
            worktrees: await worktrees,
            branches: await branches,
            remotes: await remotes,
            recentCommits: await commits
        )
    }

    // MARK: - Section loaders

    private static func loadWorktrees(in directory: String) async -> [GitWorktree] {
        guard let output = await runGit(["worktree", "list", "--porcelain"], in: directory) else { return [] }

        var result: [GitWorktree] = []
        var currentPath: String?
        var currentBranch: String?

        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let str = String(line)
            if str.hasPrefix("worktree ") {
                flush(path: &currentPath, branch: &currentBranch, into: &result, current: directory)
                currentPath = String(str.dropFirst("worktree ".count))
            } else if str.hasPrefix("branch ") {
                currentBranch = String(str.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "")
            } else if str.isEmpty {
                flush(path: &currentPath, branch: &currentBranch, into: &result, current: directory)
            }
        }
        flush(path: &currentPath, branch: &currentBranch, into: &result, current: directory)
        return result
    }

    private static func flush(
        path: inout String?,
        branch: inout String?,
        into result: inout [GitWorktree],
        current directory: String
    ) {
        if let path {
            result.append(GitWorktree(
                path: path,
                branch: branch,
                isCurrent: normalized(path) == normalized(directory)
            ))
        }
        path = nil
        branch = nil
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func loadBranches(in directory: String, current: String) async -> [GitBranch] {
        let format = "%(refname:short)|%(upstream:short)"
        guard let output = await runGit(
            ["for-each-ref", "--format=\(format)", "refs/heads/"],
            in: directory
        ) else { return [] }

        return output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .compactMap { rawLine in
                let components = rawLine.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard let nameSubstring = components.first else { return nil }
                let name = String(nameSubstring)
                let upstream = components.count > 1 ? String(components[1]) : ""
                return GitBranch(
                    name: name,
                    isCurrent: name == current,
                    upstream: upstream.isEmpty ? nil : upstream
                )
            }
    }

    private static func loadRemotes(in directory: String) async -> [GitRemote] {
        guard let output = await runGit(["remote", "-v"], in: directory) else { return [] }
        var seen = Set<String>()
        return output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .compactMap { line in
                let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                guard parts.count >= 2 else { return nil }
                let name = String(parts[0])
                guard seen.insert(name).inserted else { return nil }
                return GitRemote(name: name, url: String(parts[1]))
            }
    }

    private static func loadRecentCommits(in directory: String, limit: Int = 30) async -> [GitCommit] {
        let sep = "\u{1F}"
        let format = ["%h", "%s", "%an", "%cr"].joined(separator: sep)
        guard let output = await runGit(
            ["log", "--no-color", "-n", "\(limit)", "--format=\(format)"],
            in: directory
        ) else { return [] }

        return output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .compactMap { line -> GitCommit? in
                let parts = line.split(separator: Character(sep), maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4 else { return nil }
                return GitCommit(
                    id: String(parts[0]),
                    subject: String(parts[1]),
                    author: String(parts[2]),
                    relativeDate: String(parts[3])
                )
            }
    }

    private static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int) {
        let counts = output.split(whereSeparator: { $0 == "\t" || $0 == " " })
        let ahead = Int(counts.first ?? "0") ?? 0
        let behind = Int(counts.dropFirst().first ?? "0") ?? 0
        return (ahead, behind)
    }

    // MARK: - Process runner

    private static let processQueue = DispatchQueue(
        label: "com.xylem.git",
        qos: .utility,
        attributes: .concurrent
    )

    /// Runs git on a GCD thread: `ProcessRunner` blocks until git exits,
    /// and blocking a Swift concurrency thread per git call (seven in
    /// parallel for `status`) would starve the cooperative pool.
    /// `acceptedStatuses`: exit codes that still mean "here is the output" -
    /// `git diff --no-index` exits 1 whenever the files differ.
    static func runGit(_ arguments: [String], in directory: String, acceptedStatuses: Set<Int32> = [0]) async -> String? {
        await withCheckedContinuation { continuation in
            processQueue.async {
                continuation.resume(returning: runGitBlocking(arguments, in: directory, acceptedStatuses: acceptedStatuses))
            }
        }
    }

    /// Longest any git call may run: far above a slow `git status` in a big
    /// repository, finite for a hung one.
    static let timeout: TimeInterval = 30

    static func runGitBlocking(_ arguments: [String], in directory: String, acceptedStatuses: Set<Int32> = [0],
                               timeout: TimeInterval = timeout) -> String? {
        // --no-optional-locks: `git status` must not refresh and rewrite
        // .git/index - GitStatusViewModel watches that file, so a rewrite
        // would trigger another status refresh. A hung git (a stuck
        // fsmonitor hook, a dead network volume) is stopped at `timeout`
        // and the call fails like any git error.
        guard let result = ProcessRunner.run("/usr/bin/git", ["--no-optional-locks"] + arguments,
                                             in: directory, timeout: timeout),
              result.exited, acceptedStatuses.contains(result.status)
        else { return nil }
        // Invalid UTF-8 (a Latin-1 file in a diff) must not lose the output.
        return String(decoding: result.output, as: UTF8.self)
    }
}

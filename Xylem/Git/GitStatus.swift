//
//  GitStatus.swift
//  Xylem
//
//  Richer view of a repository's current state. Each nested type is kept
//  small and value-only so the repository layer can be unit tested by
//  constructing instances directly.
//

import Foundation

nonisolated struct GitStatus: Equatable, Sendable {
    let branch: String
    let isDirty: Bool
    let modified: Int
    let untracked: Int
    let ahead: Int
    let behind: Int
    let worktrees: [GitWorktree]
    let branches: [GitBranch]
    let remotes: [GitRemote]
    let recentCommits: [GitCommit]

    static let empty = GitStatus(
        branch: "-",
        isDirty: false,
        modified: 0,
        untracked: 0,
        ahead: 0,
        behind: 0,
        worktrees: [],
        branches: [],
        remotes: [],
        recentCommits: []
    )
}

nonisolated struct GitWorktree: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let branch: String?
    let isCurrent: Bool

    var displayName: String {
        (path as NSString).lastPathComponent
    }
}

nonisolated struct GitBranch: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let isCurrent: Bool
    let upstream: String?
}

nonisolated struct GitRemote: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let url: String
}

nonisolated struct GitCommit: Identifiable, Hashable, Sendable {
    let id: String          // short sha
    let subject: String
    let author: String
    let relativeDate: String
}

//
//  ClaudeProject.swift
//  Xylem
//
//  Immutable domain model for a Claude Code project on disk.
//  A project = one folder in ~/.claude/projects/ corresponding to a filesystem path.
//

import Foundation

nonisolated struct ClaudeProject: Identifiable, Hashable {
    let id: String                   // encoded folder name as stored on disk
    let path: String                 // decoded absolute path
    let displayName: String          // last path component, nice for the UI
    let sessionCount: Int
    let lastModified: Date
}

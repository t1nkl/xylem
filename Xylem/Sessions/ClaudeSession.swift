//
//  ClaudeSession.swift
//  Xylem
//
//  A single saved Claude Code session. Corresponds to one .jsonl file inside
//  a project folder. Title is derived from the first user-authored message.
//

import Foundation

nonisolated struct ClaudeSession: Identifiable, Hashable {
    let id: String              // uuid from filename
    let projectID: String       // encoded project folder name
    let projectPath: String     // decoded absolute path
    let title: String
    let lastModified: Date
    let fileURL: URL
    /// The whole first prompt (capped at `ClaudeSessionReader.promptCap`)
    /// for the Sessions row tooltip; `title` is its 60-character cut.
    var firstPrompt: String? = nil
}

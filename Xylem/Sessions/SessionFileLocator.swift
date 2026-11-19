//
//  SessionFileLocator.swift
//  Xylem
//
//  Centralises "find the newest jsonl for a given project cwd" - the
//  folder-name encoding and the by-mtime sort - for TabActivityViewModel,
//  SessionStatsViewModel and AllSessionsOverviewSheet.
//

import Foundation

nonisolated enum SessionFileLocator {
    /// Claude Code stores each project's sessions under
    /// `~/.claude/projects/<encoded-path>/` where every character outside
    /// `[A-Za-z0-9]` becomes `-` (see `ClaudeProjectPathResolver.encode`).
    /// Returns the newest `.jsonl` in that folder, or nil if the folder
    /// doesn't exist.
    /// `excluding` skips session ids (file names) other tabs are bound to.
    static func latestSessionFile(
        for directory: String,
        projectsDirectory: URL = defaultProjectsDirectory,
        excluding excluded: Set<String> = []
    ) -> URL? {
        let folder = projectsDirectory.appending(
            path: encodedFolderName(for: directory),
            directoryHint: .isDirectory
        )
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        // Single pass: polled every few seconds, and a project folder can
        // hold hundreds of sessions.
        var newest: (url: URL, modified: Date)?
        for file in files where file.pathExtension == "jsonl"
            && !excluded.contains(file.deletingPathExtension().lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.modified {
                newest = (file, modified)
            }
        }
        return newest?.url
    }

    /// Delegates to `ClaudeProjectPathResolver.encode` so there is exactly
    /// one copy of the encoding rule. A local `/`-only variant missed every
    /// project whose path contained `_`, `.`, spaces or non-ASCII letters.
    static func encodedFolderName(for directory: String) -> String {
        ClaudeProjectPathResolver.encode(directory)
    }

    /// `projects/` of the Claude config folder (`~/.claude`, or
    /// CLAUDE_CONFIG_DIR) with symlinks resolved: a `~/.claude` kept in a
    /// dotfiles repo and linked in is common, and Foundation's
    /// `contentsOfDirectory` does not follow a symlinked directory (ENOTDIR
    /// on macOS 27) - every list below it would come back empty. Usage, the
    /// project list and the prompt index use it too. Resolved once per
    /// change in ClaudeConfigDirectory, not per read.
    static var defaultProjectsDirectory: URL { ClaudeConfigDirectory.projects }
}
